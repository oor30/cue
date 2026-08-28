import Foundation
import CueCore
import Testing
@testable import CueApp

@Suite("MeetingDiagnosticsCollectorTests")
struct MeetingDiagnosticsCollectorTests {
    @Test func collectsPipelineCountersAndDurations() async {
        let meetingID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let collector = MeetingDiagnosticsCollector(
            meetingID: meetingID,
            startedAt: startedAt,
            codexProcessCountProvider: { 1 }
        )

        await collector.recordAudioInput(at: startedAt)
        await collector.recordFinalTranscript(
            endTime: 2,
            receivedAt: startedAt.addingTimeInterval(2.5)
        )
        let eventID = UUID()
        let analysisID = UUID()
        await collector.recordEventDetection(
            eventIDs: [eventID],
            transcriptReceivedAt: startedAt.addingTimeInterval(2.5),
            completedAt: startedAt.addingTimeInterval(2.6)
        )
        await collector.recordAnalysisStarted(
            analysisID: analysisID,
            eventID: eventID,
            mode: .fast,
            at: startedAt.addingTimeInterval(2.7)
        )
        await collector.recordAnalysisCompleted(
            analysisID: analysisID,
            at: startedAt.addingTimeInterval(3.8)
        )
        await collector.recordScreenProcessing(0.2)
        await collector.recordSQLiteWrite(0.01)
        await collector.recordCodexReconnect()
        await collector.recordTranscriptionRecovery()

        let report = await collector.finish(
            endedAt: startedAt.addingTimeInterval(10),
            audioIngress: AudioIngressDiagnostics(
                firstSubmittedAt: startedAt,
                maximumQueueDepth: 4,
                droppedBuffers: 2
            )
        )

        #expect(report.meetingID == meetingID)
        #expect(report.sttFinalLatencySeconds.p50 == 0.5)
        #expect(abs(report.sttToEventLatencySeconds.p50 - 0.1) < 0.000_001)
        #expect(abs(report.eventToFastCardLatencySeconds.p50 - 1.2) < 0.000_001)
        #expect(report.maximumAudioQueueDepth == 4)
        #expect(report.maximumPendingEventCount == 1)
        #expect(report.counters.droppedAudioBuffers == 2)
        #expect(report.counters.codexReconnects == 1)
        #expect(report.counters.transcriptionRecoveries == 1)
    }
}
