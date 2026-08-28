import AVFoundation
import CoreMedia
import Foundation
import CueCore
import Testing
@testable import CueApp

@Suite("SpeechTranscriptionQualityGateTests")
struct SpeechTranscriptionQualityGateTests {
    @Test
    func transcribesTwoSourcesBeyondPreviousStallPointWhenFixtureIsConfigured() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment[
            "MEETING_COPILOT_STT_FIXTURE"
        ] else {
            return
        }

        let isSoakTest = ProcessInfo.processInfo.environment[
            "MEETING_COPILOT_STT_SOAK"
        ] == "1"
        let fixtureDuration = min(
            isSoakTest ? 7_200 : 45,
            Double(
                ProcessInfo.processInfo.environment[
                    "MEETING_COPILOT_STT_FIXTURE_SECONDS"
                ] ?? "45"
            ) ?? 45
        )
        let fixtureStart = max(
            0,
            Double(
                ProcessInfo.processInfo.environment[
                    "MEETING_COPILOT_STT_FIXTURE_START_SECONDS"
                ] ?? "0"
            ) ?? 0
        )
        let service = SpeechTranscriptionService()
        let collector = SpeechFixtureCollector()
        let meetingID = UUID()
        let diagnosticCollector = MeetingDiagnosticsCollector(
            meetingID: meetingID,
            startedAt: Date(),
            codexProcessCountProvider: { 0 }
        )
        await diagnosticCollector.start()
        let sourceMode = ProcessInfo.processInfo.environment[
            "MEETING_COPILOT_STT_FIXTURE_SOURCE"
        ] ?? "both"
        let sources: [AudioSource] = switch sourceMode {
        case "system": [.system]
        case "microphone": [.microphone]
        default: AudioSource.allCases
        }

        let segmentTask = Task {
            for await segment in service.segments {
                guard !Task.isCancelled else { return }
                await collector.record(segment)
                if segment.isFinal {
                    await diagnosticCollector.recordFinalTranscript(
                        endTime: segment.endTime
                    )
                }
            }
        }
        let stateTask = Task {
            for await state in service.states {
                guard !Task.isCancelled else { return }
                await collector.record(state)
            }
        }

        try await service.start(meetingID: meetingID, sources: sources)
        let audioFile = try AVAudioFile(
            forReading: URL(filePath: fixturePath)
        )
        let sampleRate = audioFile.processingFormat.sampleRate
        let fixtureStartFrame = AVAudioFramePosition(sampleRate * fixtureStart)
        audioFile.framePosition = fixtureStartFrame
        let chunkDuration = 0.1
        let chunkFrames = AVAudioFrameCount(sampleRate * chunkDuration)
        let maximumFrames = AVAudioFramePosition(sampleRate * fixtureDuration)
        var submittedFrames: AVAudioFramePosition = 0
        let audioStartedAt = Date()
        await diagnosticCollector.recordAudioInput(at: audioStartedAt)

        while submittedFrames < maximumFrames {
            if audioFile.framePosition >= audioFile.length {
                guard isSoakTest, fixtureStartFrame < audioFile.length else { break }
                audioFile.framePosition = fixtureStartFrame
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: chunkFrames
            ) else {
                Issue.record("テスト用音声バッファを確保できませんでした。")
                break
            }
            let availableFrames = max(
                0,
                audioFile.length - audioFile.framePosition
            )
            let requestedFrames = AVAudioFrameCount(
                min(AVAudioFramePosition(chunkFrames), availableFrames)
            )
            guard requestedFrames > 0 else {
                guard isSoakTest else { break }
                audioFile.framePosition = fixtureStartFrame
                continue
            }
            try audioFile.read(into: buffer, frameCount: requestedFrames)
            if buffer.frameLength == 0 {
                guard isSoakTest, fixtureStartFrame < audioFile.length else { break }
                audioFile.framePosition = fixtureStartFrame
                continue
            }

            let presentationTime = CMTime(
                value: submittedFrames,
                timescale: CMTimeScale(sampleRate.rounded())
            )
            if sources.contains(.system) {
                service.submit(
                    CapturedAudioBuffer(
                        source: .system,
                        buffer: buffer,
                        presentationTime: presentationTime
                    )
                )
            }
            if sources.contains(.microphone) {
                service.submit(
                    CapturedAudioBuffer(
                        source: .microphone,
                        buffer: buffer,
                        presentationTime: presentationTime
                    )
                )
            }
            submittedFrames += AVAudioFramePosition(buffer.frameLength)
            let targetDate = audioStartedAt.addingTimeInterval(
                Double(submittedFrames) / sampleRate
            )
            let remaining = targetDate.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }

        // ScreenCaptureKitは無音時も音声バッファを供給するため、単なる待機ではなく
        // 5秒分の無音を流し、発話末尾の確定遅延を実運用に近い形で測る。
        for _ in 0..<50 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: chunkFrames
            ) else { break }
            buffer.frameLength = chunkFrames
            for audioBuffer in UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            ) {
                audioBuffer.mData?.initializeMemory(
                    as: UInt8.self,
                    repeating: 0,
                    count: Int(audioBuffer.mDataByteSize)
                )
            }
            let presentationTime = CMTime(
                value: submittedFrames,
                timescale: CMTimeScale(sampleRate.rounded())
            )
            for source in sources {
                service.submit(
                    CapturedAudioBuffer(
                        source: source,
                        buffer: buffer,
                        presentationTime: presentationTime
                    )
                )
            }
            submittedFrames += AVAudioFramePosition(chunkFrames)
            let targetDate = audioStartedAt.addingTimeInterval(
                Double(submittedFrames) / sampleRate
            )
            let remaining = targetDate.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }
        try await Task.sleep(for: .seconds(1))
        await service.stop()
        let ingressDiagnostics = service.ingressDiagnostics()
        let diagnosticReport = await diagnosticCollector.finish(
            endedAt: Date(),
            audioIngress: ingressDiagnostics
        )
        segmentTask.cancel()
        stateTask.cancel()

        let result = await collector.result()
        let finalSegments = result.segments.filter(\.isFinal)
        let systemSegments = result.segments.filter { $0.source == .system }
        let microphoneSegments = result.segments.filter { $0.source == .microphone }
        print(
            """
            STT fixture diagnostics
            states: \(result.states)
            system: all=\(systemSegments.count) final=\(systemSegments.filter(\.isFinal).count) maxEnd=\(systemSegments.map(\.endTime).max() ?? 0)
            microphone: all=\(microphoneSegments.count) final=\(microphoneSegments.filter(\.isFinal).count) maxEnd=\(microphoneSegments.map(\.endTime).max() ?? 0)
            audio ingress: maxQueue=\(ingressDiagnostics.maximumQueueDepth) dropped=\(ingressDiagnostics.droppedBuffers)
            \(MeetingDiagnosticsMarkdownFormatter.render(diagnosticReport))
            final excerpts: \(finalSegments.suffix(6).map { "\($0.source.rawValue):\($0.endTime):\($0.text)" })
            """
        )
        if sources.contains(.system) {
            #expect(finalSegments.contains { $0.source == .system })
        }
        if sources == [.microphone] {
            #expect(finalSegments.contains { $0.source == .microphone })
        } else if sources.contains(.microphone) {
            // 両系統へ同じfixtureを投入すると、確定したマイク側の複製は
            // 音響回り込みとして抑止される。入力処理自体が継続したことは
            // 暫定結果で確認し、確定能力はmicrophone単独ゲートで確認する。
            #expect(!microphoneSegments.isEmpty)
        }
        #expect(finalSegments.contains { $0.endTime > 30 })
        #expect(ingressDiagnostics.droppedBuffers == 0)
        #expect(ingressDiagnostics.maximumQueueDepth <= 256)
        if isSoakTest {
            #expect(diagnosticReport.sttFinalLatencySeconds.p95 <= 2)
            #expect(
                diagnosticReport.memoryMegabytes.end <=
                    diagnosticReport.memoryMegabytes.start + 300
            )
        }
        #expect(
            !result.states.contains {
                if case .recovering = $0 { return true }
                return false
            }
        )
        #expect(
            !result.states.contains {
                if case .failed = $0 { return true }
                return false
            }
        )
    }
}

private actor SpeechFixtureCollector {
    private var segments: [TranscriptSegment] = []
    private var states: [TranscriptionServiceState] = []

    func record(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func record(_ state: TranscriptionServiceState) {
        states.append(state)
    }

    func result() -> (
        segments: [TranscriptSegment],
        states: [TranscriptionServiceState]
    ) {
        (segments, states)
    }
}
