import CueCore
import Foundation
import Testing

@testable import CueApp

@Suite("MeetingSummaryPromptTests")
struct MeetingSummaryPromptTests {
    @Test func requestsAnAISummaryAndKeepsTranscriptEvidence() throws {
        let meetingID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 2,
            text: "この仕様で進めます",
            isFinal: true
        )
        let state = MeetingState(meetingID: meetingID)
        let event = DetectedEvent(
            meetingID: meetingID,
            topicID: state.topic.id,
            topicRevision: state.topic.revision,
            type: .importantFact,
            sourceSegmentIDs: [segment.id],
            triggerReason: "手動操作: 会議全体のAI要約",
            excerpt: "要件会議",
            localScore: 1
        )
        let request = AnalysisRequest(
            mode: .fast,
            context: MeetingContextEnvelope(
                meetingID: meetingID,
                topic: state.topic,
                state: state,
                recentTranscript: [segment],
                sourceEvent: event,
                relatedEvidence: []
            ),
            deadline: .seconds(10)
        )
        let project = ProjectConfiguration(name: "Test", rootPath: "/tmp")

        let prompt = try CodexProvider.prompt(for: request, project: project)
        #expect(prompt.contains("単なる抜粋や発言の連結ではなく"))
        #expect(prompt.contains("未回答・確認事項"))

        let response = """
        {
          "category": "research",
          "title": "AI会議要約",
          "body": "## 概要\\n仕様を確定した。",
          "importance": "high",
          "confidence": 0.9,
          "evidence": [
            {
              "kind": "transcript",
              "label": "決定の発言",
              "location": "\(segment.id.uuidString)",
              "line": null
            }
          ]
        }
        """
        let card = try CodexProvider.decodeCard(
            response,
            request: request,
            project: project
        )
        #expect(card.body.contains("仕様を確定した"))
        #expect(card.evidence.first?.location == segment.id.uuidString)
    }
}
