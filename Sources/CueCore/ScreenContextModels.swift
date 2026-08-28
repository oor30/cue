import Foundation

/// 画面全体を 0...1 で表す正規化座標。Vision と同じく原点は左下です。
public struct ScreenNormalizedRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
        self.width = min(1 - self.x, max(0, width))
        self.height = min(1 - self.y, max(0, height))
    }
}

/// キャプチャ元のピクセル座標。画像データそのものは保持しません。
public struct ScreenPixelRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenTextObservation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let confidence: Double
    public let bounds: ScreenNormalizedRect

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        bounds: ScreenNormalizedRect
    ) {
        self.id = id
        self.text = text
        self.confidence = min(1, max(0, confidence))
        self.bounds = bounds
    }
}

public enum ScreenTextChangeKind: String, Codable, Sendable {
    case added
    case modified
    case removed
}

public struct ScreenTextChange: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: ScreenTextChangeKind
    public let previous: ScreenTextObservation?
    public let current: ScreenTextObservation?

    public init(
        id: UUID = UUID(),
        kind: ScreenTextChangeKind,
        previous: ScreenTextObservation? = nil,
        current: ScreenTextObservation? = nil
    ) {
        self.id = id
        self.kind = kind
        self.previous = previous
        self.current = current
    }
}

/// OCRで得たテキストと差分だけを運ぶイベント。キャプチャ画像は含みません。
public struct ScreenContextEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let presentationTime: TimeInterval?
    public let contentRect: ScreenPixelRect?
    public let dirtyRects: [ScreenPixelRect]
    public let observations: [ScreenTextObservation]
    public let changes: [ScreenTextChange]

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        presentationTime: TimeInterval? = nil,
        contentRect: ScreenPixelRect? = nil,
        dirtyRects: [ScreenPixelRect] = [],
        observations: [ScreenTextObservation],
        changes: [ScreenTextChange]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.presentationTime = presentationTime
        self.contentRect = contentRect
        self.dirtyRects = dirtyRects
        self.observations = observations
        self.changes = changes
    }

    public var fullText: String {
        String(
            observations
                .map(\.text)
                .joined(separator: "\n")
                .prefix(4_000)
        )
    }
}
