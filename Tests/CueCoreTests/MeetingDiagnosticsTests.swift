import Foundation
import CueCore
import Testing

@Suite("MeetingDiagnosticsTests")
struct MeetingDiagnosticsTests {
    @Test
    func calculatesPercentilesAndResourceTrend() {
        let distribution = MetricDistributionSummary(
            samples: Array(1...100).map(Double.init)
        )
        let memory = ResourceUsageSummary(samples: [220, 250, 311, 284])

        #expect(distribution.count == 100)
        #expect(distribution.p50 == 51)
        #expect(distribution.p95 == 96)
        #expect(distribution.max == 100)
        #expect(memory.start == 220)
        #expect(memory.end == 284)
        #expect(memory.peak == 311)
    }

    @Test
    func rendersQualityGateReport() {
        let summary = MetricDistributionSummary(samples: [0.8, 1.7, 4.1])
        let report = MeetingDiagnosticsReport(
            meetingID: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 7_394),
            cpuPercent: MetricDistributionSummary(samples: [10, 20]),
            memoryMegabytes: ResourceUsageSummary(samples: [220, 284, 311]),
            sttFinalLatencySeconds: summary,
            sttToEventLatencySeconds: summary,
            eventToFastCardLatencySeconds: summary,
            deepAnalysisSeconds: summary,
            screenProcessingSeconds: summary,
            sqliteWriteSeconds: summary,
            codexProcessCount: ResourceUsageSummary(samples: [0, 1]),
            maximumAudioQueueDepth: 2,
            maximumPendingEventCount: 1,
            counters: MeetingDiagnosticCounters(codexReconnects: 1),
            recentErrors: []
        )

        let markdown = MeetingDiagnosticsMarkdownFormatter.render(report)
        #expect(markdown.contains("Meeting duration: 02:03:14"))
        #expect(markdown.contains("p95: 4.100 sec"))
        #expect(markdown.contains("Codex reconnects: 1"))
    }
}
