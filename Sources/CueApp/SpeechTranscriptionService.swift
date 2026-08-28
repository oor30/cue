import AVFoundation
import CoreMedia
import Foundation
import CueCore
import OSLog
import Speech

enum TranscriptionServiceError: LocalizedError {
    case unavailable
    case japaneseUnsupported
    case audioFormatUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "このMacではSpeechTranscriberを利用できません。"
        case .japaneseUnsupported:
            "日本語文字起こしモデルを利用できません。"
        case .audioFormatUnavailable:
            "文字起こし用の音声形式を取得できません。"
        case .conversionFailed(let message):
            "音声形式の変換に失敗しました: \(message)"
        }
    }
}

enum TranscriptionServiceState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case recovering(AudioSource, String)
    case failed(AudioSource, String)
    case stopped

    var label: String {
        switch self {
        case .idle:
            "文字起こし待機中"
        case .starting:
            "文字起こし準備中"
        case .listening:
            "文字起こし中"
        case .recovering(let source, _):
            "\(source == .system ? "システム音声" : "マイク")を自動復旧中"
        case .failed:
            "文字起こし停止"
        case .stopped:
            "文字起こし停止済み"
        }
    }

    var detail: String? {
        switch self {
        case .recovering(let source, let message), .failed(let source, let message):
            "\(source == .system ? "システム音声" : "マイク"): \(message)"
        default:
            nil
        }
    }

    var isHealthy: Bool {
        switch self {
        case .listening:
            true
        default:
            false
        }
    }
}

struct AudioInputTimeline: Sendable {
    private(set) var current = CMTime.zero

    mutating func takeStart(
        frameLength: AVAudioFrameCount,
        sampleRate: Double
    ) -> CMTime {
        let start = current
        current = CMTimeAdd(
            current,
            CMTime(
                value: Int64(frameLength),
                timescale: CMTimeScale(sampleRate.rounded())
            )
        )
        return start
    }
}

struct AudioIngressDiagnostics: Sendable {
    let firstSubmittedAt: Date?
    let maximumQueueDepth: Int
    let droppedBuffers: Int
}

private final class SpeechAudioIngress: @unchecked Sendable {
    private let streams: [AudioSource: AsyncStream<CapturedAudioBuffer>]
    private let continuations: [
        AudioSource: AsyncStream<CapturedAudioBuffer>.Continuation
    ]
    private let diagnosticsLock = NSLock()
    private var pendingCounts: [AudioSource: Int] = [:]
    private var firstSubmittedAt: Date?
    private var maximumQueueDepth = 0
    private var droppedBuffers = 0

    init() {
        var streams: [AudioSource: AsyncStream<CapturedAudioBuffer>] = [:]
        var continuations: [
            AudioSource: AsyncStream<CapturedAudioBuffer>.Continuation
        ] = [:]
        for source in AudioSource.allCases {
            let stream = AsyncStream.makeStream(
                of: CapturedAudioBuffer.self,
                bufferingPolicy: .bufferingNewest(128)
            )
            streams[source] = stream.stream
            continuations[source] = stream.continuation
        }
        self.streams = streams
        self.continuations = continuations
    }

    func stream(for source: AudioSource) -> AsyncStream<CapturedAudioBuffer> {
        guard let stream = streams[source] else {
            preconditionFailure("AudioSource.allCasesにない入力です。")
        }
        return stream
    }

    func submit(_ captured: CapturedAudioBuffer) {
        diagnosticsLock.lock()
        if firstSubmittedAt == nil {
            firstSubmittedAt = Date()
        }
        pendingCounts[captured.source, default: 0] += 1
        maximumQueueDepth = max(
            maximumQueueDepth,
            pendingCounts.values.reduce(0, +)
        )
        diagnosticsLock.unlock()

        guard let result = continuations[captured.source]?.yield(captured) else {
            didReject(captured.source, dropped: true)
            return
        }
        switch result {
        case .enqueued:
            break
        case .dropped:
            // bufferingNewestは古い要素を1件破棄して新しい要素を受理するため、
            // 待機数は増えず、破棄数だけを加算する。
            didReject(captured.source, dropped: true)
        case .terminated:
            didReject(captured.source, dropped: false)
        @unknown default:
            didReject(captured.source, dropped: true)
        }
    }

    func didConsume(_ source: AudioSource) {
        diagnosticsLock.lock()
        pendingCounts[source] = max(0, pendingCounts[source, default: 0] - 1)
        diagnosticsLock.unlock()
    }

    func resetDiagnostics() {
        diagnosticsLock.lock()
        pendingCounts = [:]
        firstSubmittedAt = nil
        maximumQueueDepth = 0
        droppedBuffers = 0
        diagnosticsLock.unlock()
    }

    func diagnostics() -> AudioIngressDiagnostics {
        diagnosticsLock.lock()
        let diagnostics = AudioIngressDiagnostics(
            firstSubmittedAt: firstSubmittedAt,
            maximumQueueDepth: maximumQueueDepth,
            droppedBuffers: droppedBuffers
        )
        diagnosticsLock.unlock()
        return diagnostics
    }

    private func didReject(_ source: AudioSource, dropped: Bool) {
        diagnosticsLock.lock()
        pendingCounts[source] = max(0, pendingCounts[source, default: 0] - 1)
        if dropped {
            droppedBuffers += 1
        }
        diagnosticsLock.unlock()
    }
}

actor SpeechTranscriptionService {
    nonisolated let segments: AsyncStream<TranscriptSegment>
    nonisolated let states: AsyncStream<TranscriptionServiceState>

    private let segmentContinuation: AsyncStream<TranscriptSegment>.Continuation
    private let stateContinuation: AsyncStream<TranscriptionServiceState>.Continuation
    private nonisolated let ingress = SpeechAudioIngress()
    private var channels: [AudioSource: SpeechChannel] = [:]
    private var channelGenerations: [AudioSource: UUID] = [:]
    private var ingressTasks: [AudioSource: Task<Void, Never>] = [:]
    private var recoveringSources: Set<AudioSource> = []
    private var recoveryTimestamps: [AudioSource: [Date]] = [:]
    private var meetingID: UUID?
    private var locale: Locale?
    private var echoSuppressor = TranscriptEchoSuppressor()
    private let logger = Logger(
        subsystem: "jp.cue.app",
        category: "transcription"
    )

    init() {
        let segmentStream = AsyncStream.makeStream(
            of: TranscriptSegment.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        self.segments = segmentStream.stream
        self.segmentContinuation = segmentStream.continuation

        let stateStream = AsyncStream.makeStream(
            of: TranscriptionServiceState.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.states = stateStream.stream
        self.stateContinuation = stateStream.continuation
    }

    func start(
        meetingID: UUID,
        sources: [AudioSource] = AudioSource.allCases
    ) async throws {
        stateContinuation.yield(.starting)
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionServiceError.unavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "ja_JP")
        ) else {
            throw TranscriptionServiceError.japaneseUnsupported
        }

        let probe = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        try await ensureAssets(for: [probe], locale: locale)

        ingress.resetDiagnostics()
        recoveryTimestamps.removeAll()
        echoSuppressor = TranscriptEchoSuppressor()
        ensureIngressTasksStarted()
        self.meetingID = meetingID
        self.locale = locale
        var newChannels: [AudioSource: SpeechChannel] = [:]
        var newGenerations: [AudioSource: UUID] = [:]
        do {
            for source in sources {
                let generation = UUID()
                let channel = makeChannel(
                    source: source,
                    meetingID: meetingID,
                    locale: locale,
                    generation: generation,
                    timelineOffset: 0
                )
                try await channel.start()
                newChannels[source] = channel
                newGenerations[source] = generation
            }
        } catch {
            for channel in newChannels.values {
                await channel.finish()
            }
            self.meetingID = nil
            self.locale = nil
            throw error
        }
        channels = newChannels
        channelGenerations = newGenerations
        stateContinuation.yield(.listening)
    }

    nonisolated func submit(_ captured: CapturedAudioBuffer) {
        ingress.submit(captured)
    }

    nonisolated func ingressDiagnostics() -> AudioIngressDiagnostics {
        ingress.diagnostics()
    }

    private func appendOrdered(_ captured: CapturedAudioBuffer) async {
        guard meetingID != nil, let channel = channels[captured.source] else { return }
        await channel.append(captured)
    }

    func stop() async {
        let activeChannels = channels.values
        channels.removeAll()
        channelGenerations.removeAll()
        recoveringSources.removeAll()
        recoveryTimestamps.removeAll()
        meetingID = nil
        locale = nil
        echoSuppressor = TranscriptEchoSuppressor()
        for channel in activeChannels {
            await channel.finish()
        }
        stateContinuation.yield(.stopped)
    }

    private func ensureIngressTasksStarted() {
        guard ingressTasks.isEmpty else { return }
        for source in AudioSource.allCases {
            let stream = ingress.stream(for: source)
            ingressTasks[source] = Task { [weak self, stream] in
                for await captured in stream {
                    guard !Task.isCancelled else { return }
                    self?.ingress.didConsume(source)
                    await self?.appendOrdered(captured)
                }
            }
        }
    }

    private func makeChannel(
        source: AudioSource,
        meetingID: UUID,
        locale: Locale,
        generation: UUID,
        timelineOffset: TimeInterval
    ) -> SpeechChannel {
        SpeechChannel(
            source: source,
            meetingID: meetingID,
            locale: locale,
            timelineOffset: timelineOffset,
            outputHandler: { [weak self] segment in
                Task { await self?.emit(segment) }
            },
            failureHandler: { [weak self] source, message in
                Task {
                    await self?.recoverChannel(
                        source: source,
                        generation: generation,
                        message: message
                    )
                }
            }
        )
    }

    private func emit(_ segment: TranscriptSegment) {
        guard !echoSuppressor.shouldSuppress(segment) else {
            logger.info(
                "マイク回り込みの重複文字起こしを抑止しました segment=\(segment.id.uuidString, privacy: .public)"
            )
            return
        }
        segmentContinuation.yield(segment)
    }

    private func recoverChannel(
        source: AudioSource,
        generation: UUID,
        message: String
    ) async {
        guard let meetingID,
              let locale,
              channelGenerations[source] == generation,
              let failedChannel = channels[source],
              recoveringSources.insert(source).inserted
        else { return }

        let now = Date()
        let recentRecoveries = recoveryTimestamps[source, default: []]
            .filter { now.timeIntervalSince($0) < 60 }
        guard recentRecoveries.count < 3 else {
            let stopReason = "短時間に3回復旧しても安定しなかったため、この音源の文字起こしを停止しました。"
            channels[source] = nil
            channelGenerations[source] = nil
            recoveringSources.remove(source)
            await failedChannel.cancelAfterFailure()
            stateContinuation.yield(.failed(source, stopReason))
            logger.fault(
                "文字起こしの連続復旧を停止しました source=\(source.rawValue, privacy: .public)"
            )
            return
        }
        recoveryTimestamps[source] = recentRecoveries + [now]

        stateContinuation.yield(.recovering(source, message))
        logger.error(
            "文字起こしを復旧します source=\(source.rawValue, privacy: .public) reason=\(message, privacy: .public)"
        )
        let timelineOffset = await failedChannel.timelineEnd
        channels[source] = nil
        channelGenerations[source] = nil
        await failedChannel.cancelAfterFailure()

        defer { recoveringSources.remove(source) }
        var lastError = message
        for attempt in 1...3 {
            do {
                try await Task.sleep(for: .milliseconds(400 * attempt))
                guard self.meetingID == meetingID else { return }

                let replacementGeneration = UUID()
                let replacement = makeChannel(
                    source: source,
                    meetingID: meetingID,
                    locale: locale,
                    generation: replacementGeneration,
                    timelineOffset: timelineOffset
                )
                try await replacement.start()
                guard self.meetingID == meetingID else {
                    await replacement.finish()
                    return
                }
                channels[source] = replacement
                channelGenerations[source] = replacementGeneration
                recoveringSources.remove(source)
                if recoveringSources.isEmpty {
                    stateContinuation.yield(.listening)
                }
                logger.info(
                    "文字起こしの復旧に成功しました source=\(source.rawValue, privacy: .public)"
                )
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        stateContinuation.yield(.failed(source, lastError))
        logger.fault(
            "文字起こしの復旧に失敗しました source=\(source.rawValue, privacy: .public) reason=\(lastError, privacy: .public)"
        )
    }

    private func ensureAssets(
        for modules: [any SpeechModule],
        locale: Locale
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else { return }
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) {
            try await request.downloadAndInstall()
        }
    }
}

private actor SpeechChannel {
    typealias FailureHandler = @Sendable (AudioSource, String) -> Void
    typealias OutputHandler = @Sendable (TranscriptSegment) -> Void

    private let source: AudioSource
    private let meetingID: UUID
    private let timelineOffset: TimeInterval
    private let outputHandler: OutputHandler
    private let failureHandler: FailureHandler
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    private var resultTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var inputTimeline = AudioInputTimeline()
    private var latestInputEnd: TimeInterval
    private var activeSegment: ActiveTranscriptSegment?
    private var revisions: [UUID: Int] = [:]
    private var consecutiveConversionFailures = 0
    private var lastResultAt = Date()
    private var lastAudibleInputAt: Date?
    private var isStopping = false
    private var failureReported = false

    var timelineEnd: TimeInterval {
        max(
            latestInputEnd,
            timelineOffset + max(0, CMTimeGetSeconds(inputTimeline.current))
        )
    }

    init(
        source: AudioSource,
        meetingID: UUID,
        locale: Locale,
        timelineOffset: TimeInterval,
        outputHandler: @escaping OutputHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.source = source
        self.meetingID = meetingID
        self.timelineOffset = timelineOffset
        self.latestInputEnd = timelineOffset
        self.outputHandler = outputHandler
        self.failureHandler = failureHandler
        self.transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .high, modelRetention: .processLifetime)
        )
        let stream = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        self.inputStream = stream.stream
        self.inputContinuation = stream.continuation
    }

    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionServiceError.audioFormatUnavailable
        }
        analyzerFormat = format
        try await analyzer.prepareToAnalyze(in: format)

        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    await self?.handle(result)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.reportUnexpectedStop(error.localizedDescription)
            }
        }
        analyzerTask = Task { [weak self, analyzer, inputStream] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                return
            } catch {
                await self?.reportUnexpectedStop(error.localizedDescription)
            }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await self?.checkForStall()
            }
        }
    }

    func append(_ captured: CapturedAudioBuffer) async {
        guard !isStopping, !failureReported else { return }
        do {
            let converted = try convertedBuffer(captured.buffer)
            guard converted.frameLength > 0 else { return }
            consecutiveConversionFailures = 0
            if isAudible(converted) {
                let now = Date()
                if lastAudibleInputAt.map({ now.timeIntervalSince($0) >= 8 }) ?? true {
                    lastResultAt = now
                }
                lastAudibleInputAt = now
            }

            let analyzerStartTime = inputTimeline.takeStart(
                frameLength: converted.frameLength,
                sampleRate: converted.format.sampleRate
            )
            latestInputEnd = max(
                latestInputEnd,
                timelineOffset + CMTimeGetSeconds(inputTimeline.current)
            )
            let result = inputContinuation.yield(
                AnalyzerInput(
                    buffer: converted,
                    bufferStartTime: analyzerStartTime
                )
            )
            if case .terminated = result {
                reportFailure("音声認識の入力ストリームが終了しました。")
            }
        } catch {
            consecutiveConversionFailures += 1
            if consecutiveConversionFailures >= 3 {
                reportFailure(error.localizedDescription)
            }
        }
    }

    func finish() async {
        isStopping = true
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        analyzerTask?.cancel()
        resultTask?.cancel()
        watchdogTask?.cancel()
        analyzerTask = nil
        resultTask = nil
        watchdogTask = nil
    }

    func cancelAfterFailure() async {
        isStopping = true
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        analyzerTask?.cancel()
        resultTask?.cancel()
        watchdogTask?.cancel()
        analyzerTask = nil
        resultTask = nil
        watchdogTask = nil
    }

    private func reportUnexpectedStop(_ message: String) {
        guard !isStopping, !Task.isCancelled else { return }
        reportFailure(message)
    }

    private func reportFailure(_ message: String) {
        guard !isStopping, !failureReported else { return }
        failureReported = true
        inputContinuation.finish()
        failureHandler(source, message)
    }

    private func checkForStall(now: Date = Date()) {
        guard !isStopping,
              !failureReported,
              let lastAudibleInputAt,
              now.timeIntervalSince(lastAudibleInputAt) < 8,
              now.timeIntervalSince(lastResultAt) > 30
        else { return }
        reportFailure("音声は届いていますが、30秒以上認識結果が更新されませんでした。")
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        lastResultAt = Date()
        let start = timelineOffset + max(0, CMTimeGetSeconds(result.range.start))
        let duration = max(0, CMTimeGetSeconds(result.range.duration))
        let end = start + duration
        let matchingActiveSegment = activeSegment.flatMap { active in
            let overlaps = start <= active.endTime + 0.25 &&
                end >= active.startTime - 0.25
            return overlaps ? active : nil
        }
        let id = matchingActiveSegment?.id ?? UUID()
        let canonicalStart = matchingActiveSegment?.startTime ?? start
        let canonicalEnd = max(matchingActiveSegment?.endTime ?? end, end)
        let revision = (revisions[id] ?? -1) + 1
        revisions[id] = revision

        let segment = TranscriptSegment(
            id: id,
            meetingID: meetingID,
            source: source,
            speaker: source == .microphone ? .selfSpeaker : .other,
            startTime: canonicalStart,
            endTime: canonicalEnd,
            text: String(result.text.characters),
            isFinal: result.isFinal,
            revision: revision
        )
        outputHandler(segment)

        if result.isFinal {
            activeSegment = nil
            revisions.removeValue(forKey: id)
        } else {
            activeSegment = ActiveTranscriptSegment(
                id: id,
                startTime: canonicalStart,
                endTime: canonicalEnd
            )
        }
    }

    private func convertedBuffer(
        _ input: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        guard let analyzerFormat else {
            throw TranscriptionServiceError.audioFormatUnavailable
        }
        if input.format == analyzerFormat {
            return input
        }

        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: analyzerFormat)
            converterInputFormat = input.format
        }
        guard let converter else {
            throw TranscriptionServiceError.conversionFailed("converter unavailable")
        }

        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * ratio)
        ) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else {
            throw TranscriptionServiceError.conversionFailed("buffer allocation")
        }

        let inputProvider = ConverterInputProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }

        guard status == .haveData || status == .inputRanDry else {
            throw TranscriptionServiceError.conversionFailed(
                conversionError?.localizedDescription ?? "status \(status.rawValue)"
            )
        }
        return outputBuffer
    }

    private func isAudible(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0
        else { return false }
        let sampleCount = Int(buffer.frameLength)
        let stride = max(1, sampleCount / 256)
        var sum: Float = 0
        var measured = 0
        for index in Swift.stride(from: 0, to: sampleCount, by: stride) {
            let sample = channels[0][index]
            sum += sample * sample
            measured += 1
        }
        guard measured > 0 else { return false }
        return sqrt(sum / Float(measured)) >= 0.004
    }
}

private struct ActiveTranscriptSegment: Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
