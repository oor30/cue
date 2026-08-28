import Foundation

public enum AnalysisStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case stale
    case cancelled
    case timedOut
    case failed
}

public enum AnalysisFreshness: String, Codable, Hashable, Sendable {
    case current
    case relatedButOld
    case stale
}

public struct AnalysisRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let topicID: UUID
    public let eventID: UUID
    public let createdAt: Date
    public let contextRevision: Int
    public let mode: AnalysisMode
    public var status: AnalysisStatus
    public var completedAt: Date?
    public var errorMessage: String?

    public init(
        id: UUID,
        meetingID: UUID,
        topicID: UUID,
        eventID: UUID,
        createdAt: Date = Date(),
        contextRevision: Int,
        mode: AnalysisMode,
        status: AnalysisStatus = .queued,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.topicID = topicID
        self.eventID = eventID
        self.createdAt = createdAt
        self.contextRevision = contextRevision
        self.mode = mode
        self.status = status
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

public struct AnalysisFreshnessEvaluator: Sendable {
    public init() {}

    public func evaluate(
        _ analysis: AnalysisRecord,
        currentMeetingID: UUID?,
        currentState: MeetingState?
    ) -> AnalysisFreshness {
        guard analysis.meetingID == currentMeetingID,
              let currentState,
              currentState.meetingID == analysis.meetingID,
              currentState.topic.id == analysis.topicID
        else { return .stale }

        if currentState.revision == analysis.contextRevision {
            return .current
        }
        return .relatedButOld
    }
}

public struct TopicTransitionDetector: Sendable {
    public init() {}

    public func transitionedTopic(
        for segment: TranscriptSegment,
        current: MeetingTopic
    ) -> MeetingTopic? {
        guard segment.isFinal else { return nil }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.range(
                of: #"(次の(議題|話題|テーマ|件)|次に移|続いて|別件|話題を変|話を変|ところで.{0,12}(ですが|ですけど))"#,
                options: .regularExpression
              ) != nil
        else { return nil }

        return MeetingTopic(
            revision: current.revision + 1,
            title: String(text.prefix(80)),
            startedAt: segment.createdAt
        )
    }
}
