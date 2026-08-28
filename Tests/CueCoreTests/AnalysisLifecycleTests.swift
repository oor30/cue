import Foundation
import Testing
@testable import CueCore

@Suite("AnalysisLifecycleTests")
struct AnalysisLifecycleTests {
    @Test func classifiesCurrentRelatedAndStaleResults() {
        let meetingID = UUID()
        var state = MeetingState(meetingID: meetingID)
        state.revision = 3
        let record = AnalysisRecord(
            id: UUID(),
            meetingID: meetingID,
            topicID: state.topic.id,
            eventID: UUID(),
            contextRevision: 3,
            mode: .deep
        )
        let evaluator = AnalysisFreshnessEvaluator()

        #expect(
            evaluator.evaluate(
                record,
                currentMeetingID: meetingID,
                currentState: state
            ) == .current
        )

        state.revision = 4
        #expect(
            evaluator.evaluate(
                record,
                currentMeetingID: meetingID,
                currentState: state
            ) == .relatedButOld
        )

        state.topic = MeetingTopic(revision: 1, title: "別トピック")
        #expect(
            evaluator.evaluate(
                record,
                currentMeetingID: meetingID,
                currentState: state
            ) == .stale
        )
    }

    @Test func detectsExplicitTopicTransitionOnlyFromFinalText() {
        let meetingID = UUID()
        let current = MeetingTopic(title: "Topic A")
        let detector = TopicTransitionDetector()
        let final = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 10,
            endTime: 12,
            text: "続いて、公開設定について確認します。",
            isFinal: true
        )
        let partial = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 10,
            endTime: 11,
            text: "続いて",
            isFinal: false
        )

        let transitioned = detector.transitionedTopic(for: final, current: current)
        #expect(transitioned?.id != current.id)
        #expect(transitioned?.revision == current.revision + 1)
        #expect(detector.transitionedTopic(for: partial, current: current) == nil)
    }
}
