import CoreMedia
import Foundation
import CueCore
import Vision

final class ScreenContextService: @unchecked Sendable {
    typealias ContextHandler = @Sendable (String) -> Void
    typealias EventHandler = @Sendable (ScreenContextEvent) -> Void
    typealias MetricsHandler = @Sendable (TimeInterval) -> Void

    private let continuation: AsyncStream<CapturedScreenFrame>.Continuation
    private let worker: Task<Void, Never>

    init(
        eventHandler: @escaping EventHandler,
        metricsHandler: @escaping MetricsHandler = { _ in }
    ) {
        let frames = AsyncStream.makeStream(
            of: CapturedScreenFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = frames.continuation
        self.worker = Task.detached(priority: .utility) {
            var previous: [ScreenTextObservation] = []
            var lastProcessed = ContinuousClock.now - .seconds(5)

            for await frame in frames.stream {
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                guard now - lastProcessed >= .seconds(2) else { continue }
                lastProcessed = now

                let processingStartedAt = Date()
                let observations = Self.recognizeText(in: frame.pixelBuffer)
                metricsHandler(Date().timeIntervalSince(processingStartedAt))

                let changes = Self.diff(current: observations, previous: previous)
                guard !changes.isEmpty else { continue }
                previous = observations

                eventHandler(
                    ScreenContextEvent(
                        capturedAt: frame.capturedAt,
                        presentationTime: Self.seconds(frame.presentationTime),
                        contentRect: frame.contentRect.map(Self.pixelRect),
                        dirtyRects: frame.dirtyRects.map(Self.pixelRect),
                        observations: observations,
                        changes: changes
                    )
                )
            }
        }
    }

    /// 既存のAppModel向け互換APIです。
    convenience init(
        contextHandler: @escaping ContextHandler,
        metricsHandler: @escaping MetricsHandler = { _ in }
    ) {
        self.init(
            eventHandler: { event in contextHandler(event.fullText) },
            metricsHandler: metricsHandler
        )
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func submit(_ frame: CapturedScreenFrame) {
        continuation.yield(frame)
    }

    private static func recognizeText(
        in pixelBuffer: CVPixelBuffer
    ) -> [ScreenTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? [])
            .compactMap { observation -> ScreenTextObservation? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !text.isEmpty else { return nil }
                let bounds = observation.boundingBox
                return ScreenTextObservation(
                    text: text,
                    confidence: Double(candidate.confidence),
                    bounds: ScreenNormalizedRect(
                        x: bounds.origin.x,
                        y: bounds.origin.y,
                        width: bounds.width,
                        height: bounds.height
                    )
                )
            }
            .prefix(200)
            .map { $0 }
    }

    private static func diff(
        current: [ScreenTextObservation],
        previous: [ScreenTextObservation]
    ) -> [ScreenTextChange] {
        var unmatchedPrevious = Set(previous.indices)
        var changes: [ScreenTextChange] = []

        for observation in current {
            if let exactIndex = unmatchedPrevious.first(where: {
                canonical(previous[$0].text) == canonical(observation.text)
            }) {
                unmatchedPrevious.remove(exactIndex)
                continue
            }

            let modifiedIndex = unmatchedPrevious
                .map { index in
                    (index, modificationScore(previous[index], observation))
                }
                .filter { $0.1 >= 0.55 }
                .max { $0.1 < $1.1 }?
                .0

            if let modifiedIndex {
                unmatchedPrevious.remove(modifiedIndex)
                changes.append(
                    ScreenTextChange(
                        kind: .modified,
                        previous: previous[modifiedIndex],
                        current: observation
                    )
                )
            } else {
                changes.append(
                    ScreenTextChange(kind: .added, current: observation)
                )
            }
        }

        changes.append(
            contentsOf: unmatchedPrevious.sorted().map {
                ScreenTextChange(kind: .removed, previous: previous[$0])
            }
        )
        return changes
    }

    private static func modificationScore(
        _ previous: ScreenTextObservation,
        _ current: ScreenTextObservation
    ) -> Double {
        let textScore = TranscriptEchoSuppressor.japaneseBigramSimilarity(
            previous.text,
            current.text
        )
        let spatialScore = intersectionOverUnion(previous.bounds, current.bounds)
        return (textScore * 0.65) + (spatialScore * 0.35)
    }

    private static func intersectionOverUnion(
        _ lhs: ScreenNormalizedRect,
        _ rhs: ScreenNormalizedRect
    ) -> Double {
        let left = max(lhs.x, rhs.x)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = max(lhs.y, rhs.y)
        let top = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, top - bottom)
        let union = (lhs.width * lhs.height) + (rhs.width * rhs.height) - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func canonical(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    private static func seconds(_ time: CMTime) -> TimeInterval? {
        guard time.isValid, time.isNumeric else { return nil }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : nil
    }

    private static func pixelRect(_ rect: CGRect) -> ScreenPixelRect {
        ScreenPixelRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }
}
