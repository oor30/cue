import Foundation
import CueCore
import Testing

@Suite("MeetingReviewMarkdownFormatterTests")
struct MeetingReviewMarkdownFormatterTests {
    @Test
    func rendersDecisionsImportantCardsAndTranscript() {
        let meetingID = UUID()
        let review = MeetingReviewSnapshot(
            meetingID: meetingID,
            title: "要件定義会議",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 125),
            finalTranscript: [
                TranscriptSegment(
                    meetingID: meetingID,
                    source: .microphone,
                    speaker: .selfSpeaker,
                    startTime: 65,
                    endTime: 68,
                    text: "確認します。",
                    isFinal: true
                )
            ],
            decisions: ["この仕様で進める"],
            questions: [],
            requirements: [],
            actionItems: ["担当者が確認する"],
            risks: []
        )
        let card = SuggestionCard(
            meetingID: meetingID,
            sourceEventID: UUID(),
            topicRevision: 0,
            category: .risk,
            title: "移行リスク",
            body: "切り戻し手順を確認する。",
            importance: .high,
            confidence: 0.82,
            evidence: [],
            mode: .deep
        )

        let markdown = MeetingReviewMarkdownFormatter.render(
            review: review,
            cards: [card],
            aiSummary: MeetingAISummary(
                meetingID: meetingID,
                markdown: "### 概要\n仕様と担当を確認した。",
                evidence: [],
                provider: .codex
            )
        )

        #expect(markdown.contains("# 要件定義会議"))
        #expect(markdown.contains("- この仕様で進める"))
        #expect(markdown.contains("**移行リスク**（確信度 82%）"))
        #expect(markdown.contains("[01:05] **自分**: 確認します。"))
        #expect(markdown.contains("所要時間: 2分5秒"))
        #expect(markdown.contains("## AI会議要約"))
        #expect(markdown.contains("仕様と担当を確認した。"))
    }

    @Test func includesDiagnosticsWhenProvided() {
        let meetingID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let review = MeetingReviewSnapshot(
            meetingID: meetingID,
            title: "診断付き会議",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            finalTranscript: [],
            decisions: [],
            questions: [],
            requirements: [],
            actionItems: [],
            risks: []
        )
        let diagnostics = MeetingDiagnosticsReport(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            cpuPercent: MetricDistributionSummary(samples: [12]),
            memoryMegabytes: ResourceUsageSummary(samples: [100, 110]),
            sttFinalLatencySeconds: MetricDistributionSummary(samples: [0.8]),
            sttToEventLatencySeconds: MetricDistributionSummary(samples: [0.1]),
            eventToFastCardLatencySeconds: MetricDistributionSummary(samples: [2]),
            deepAnalysisSeconds: MetricDistributionSummary(samples: []),
            screenProcessingSeconds: MetricDistributionSummary(samples: [0.2]),
            sqliteWriteSeconds: MetricDistributionSummary(samples: [0.01]),
            codexProcessCount: ResourceUsageSummary(samples: [1]),
            maximumAudioQueueDepth: 2,
            maximumPendingEventCount: 1,
            counters: MeetingDiagnosticCounters(),
            recentErrors: []
        )

        let markdown = MeetingReviewMarkdownFormatter.render(
            review: review,
            diagnostics: diagnostics
        )

        #expect(markdown.contains("## 診断レポート"))
        #expect(markdown.contains("STT final latency"))
        #expect(markdown.contains("Memory: start 100.000 MB"))
    }
}
