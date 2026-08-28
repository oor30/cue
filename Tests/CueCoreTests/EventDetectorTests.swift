import Foundation
import Testing
@testable import CueCore

struct EventDetectorTests {
    private let meetingID = UUID()

    @Test func detectsQuestionAndRequirement() {
        let detector = RuleBasedEventDetector()
        let state = MeetingState(meetingID: meetingID)
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 2,
            text: "管理者以外も使えるようにできますか？",
            isFinal: true
        )

        let events = detector.detect(in: segment, state: state)
        #expect(events.contains { $0.type == .question })
        #expect(events.contains { $0.type == .requirement })
    }

    @Test func ignoresVolatileTranscript() {
        let detector = RuleBasedEventDetector()
        let state = MeetingState(meetingID: meetingID)
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 0,
            endTime: 1,
            text: "確認します",
            isFinal: false
        )

        #expect(detector.detect(in: segment, state: state).isEmpty)
    }

    @Test func reducerPreservesDetectedFacts() {
        let initial = MeetingState(meetingID: meetingID)
        let event = DetectedEvent(
            meetingID: meetingID,
            topicID: initial.topic.id,
            topicRevision: 0,
            type: .decision,
            sourceSegmentIDs: [],
            triggerReason: "test",
            excerpt: "この仕様で進めます",
            localScore: 0.9
        )

        let updated = MeetingStateReducer().reducing(initial, with: [event])
        #expect(updated.decisions == ["この仕様で進めます"])
        #expect(updated.revision == 1)
    }

    @Test func engineDeduplicatesSameEvent() async {
        let engine = EventDetectionEngine(deduplicationInterval: 90)
        let state = MeetingState(meetingID: meetingID)
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 1,
            text: "確認しておきます",
            isFinal: true
        )
        let now = Date()

        let first = await engine.process(segment: segment, state: state, now: now)
        let second = await engine.process(
            segment: segment,
            state: state,
            now: now.addingTimeInterval(10)
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }
}
