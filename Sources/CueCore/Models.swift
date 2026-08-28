import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public enum MeetingProfile: String, Codable, CaseIterable, Sendable {
    case systemEngineer
    case sales
    case projectManager
    case custom

    public var displayName: String {
        switch self {
        case .systemEngineer: "System Engineer"
        case .sales: "Sales"
        case .projectManager: "Project Manager"
        case .custom: "Custom"
        }
    }
}

public struct ProjectConfiguration: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var additionalReferencePaths: [String]
    public var excludedPaths: [String]
    public var priorityFiles: [String]
    public var provider: AIProviderKind
    public var profile: MeetingProfile
    public var webSearchEnabled: Bool
    public var customProfilePrompt: String
    public var projectPrompt: String
    public var meetingPrompt: String
    public var backlogConfiguration: BacklogConfiguration?
    public var participantNames: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        additionalReferencePaths: [String] = [],
        excludedPaths: [String] = [],
        priorityFiles: [String] = [],
        provider: AIProviderKind = .codex,
        profile: MeetingProfile = .systemEngineer,
        webSearchEnabled: Bool = false,
        customProfilePrompt: String = "",
        projectPrompt: String = "",
        meetingPrompt: String = "",
        backlogConfiguration: BacklogConfiguration? = nil,
        participantNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.additionalReferencePaths = additionalReferencePaths
        self.excludedPaths = excludedPaths
        self.priorityFiles = priorityFiles
        self.provider = provider
        self.profile = profile
        self.webSearchEnabled = webSearchEnabled
        self.customProfilePrompt = customProfilePrompt
        self.projectPrompt = projectPrompt
        self.meetingPrompt = meetingPrompt
        self.backlogConfiguration = backlogConfiguration
        self.participantNames = participantNames
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, additionalReferencePaths, excludedPaths
        case priorityFiles, provider, profile, webSearchEnabled
        case customProfilePrompt, projectPrompt, meetingPrompt, backlogConfiguration
        case participantNames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        additionalReferencePaths = try container.decodeIfPresent(
            [String].self,
            forKey: .additionalReferencePaths
        ) ?? []
        excludedPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedPaths
        ) ?? []
        priorityFiles = try container.decodeIfPresent(
            [String].self,
            forKey: .priorityFiles
        ) ?? []
        provider = try container.decodeIfPresent(
            AIProviderKind.self,
            forKey: .provider
        ) ?? .codex
        profile = try container.decodeIfPresent(
            MeetingProfile.self,
            forKey: .profile
        ) ?? .systemEngineer
        webSearchEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .webSearchEnabled
        ) ?? false
        customProfilePrompt = try container.decodeIfPresent(
            String.self,
            forKey: .customProfilePrompt
        ) ?? ""
        projectPrompt = try container.decodeIfPresent(
            String.self,
            forKey: .projectPrompt
        ) ?? ""
        meetingPrompt = try container.decodeIfPresent(
            String.self,
            forKey: .meetingPrompt
        ) ?? ""
        backlogConfiguration = try container.decodeIfPresent(
            BacklogConfiguration.self,
            forKey: .backlogConfiguration
        )
        participantNames = try container.decodeIfPresent(
            [String].self,
            forKey: .participantNames
        ) ?? []
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case preparing
    case active
    case paused
    case reviewing
    case completed
    case failed
}

public struct MeetingRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var title: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var codexFastThreadID: String?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: MeetingStatus = .preparing,
        codexFastThreadID: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.codexFastThreadID = codexFastThreadID
    }
}

public struct MeetingPauseInterval: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
}

public enum SpeakerIdentity: String, Codable, Sendable {
    case selfSpeaker
    case other
    case unknown
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let source: AudioSource
    public let speaker: SpeakerIdentity
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var text: String
    public var isFinal: Bool
    public var revision: Int
    public var confidence: Double?
    public var speakerLabel: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        source: AudioSource,
        speaker: SpeakerIdentity,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool,
        revision: Int = 0,
        confidence: Double? = nil,
        speakerLabel: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.revision = revision
        self.confidence = confidence
        self.speakerLabel = speakerLabel
        self.createdAt = createdAt
    }

    public var displaySpeakerName: String {
        if let speakerLabel,
           !speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return speakerLabel
        }
        return switch speaker {
        case .selfSpeaker: "自分"
        case .other: "参加者"
        case .unknown: "不明"
        }
    }
}

public enum MeetingEventType: String, Codable, CaseIterable, Sendable {
    case question
    case requirement
    case specificationChange
    case contradiction
    case decision
    case actionItem
    case risk
    case importantFact
    case stalledDiscussion
}

public enum EventState: String, Codable, Sendable {
    case provisional
    case validated
    case dismissed
    case expired
}

public struct DetectedEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let topicID: UUID
    public let topicRevision: Int
    public let type: MeetingEventType
    public let sourceSegmentIDs: [UUID]
    public let triggerReason: String
    public let excerpt: String
    public let localScore: Double
    public let noveltyScore: Double
    public let detectedAt: Date
    public var state: EventState

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        topicID: UUID,
        topicRevision: Int,
        type: MeetingEventType,
        sourceSegmentIDs: [UUID],
        triggerReason: String,
        excerpt: String,
        localScore: Double,
        noveltyScore: Double = 1,
        detectedAt: Date = Date(),
        state: EventState = .provisional
    ) {
        self.id = id
        self.meetingID = meetingID
        self.topicID = topicID
        self.topicRevision = topicRevision
        self.type = type
        self.sourceSegmentIDs = sourceSegmentIDs
        self.triggerReason = triggerReason
        self.excerpt = excerpt
        self.localScore = localScore
        self.noveltyScore = noveltyScore
        self.detectedAt = detectedAt
        self.state = state
    }
}

public enum SuggestionCategory: String, Codable, CaseIterable, Sendable {
    case answer
    case question
    case contradiction
    case specification
    case research
    case decision
    case actionItem
    case risk

    public var symbol: String {
        switch self {
        case .answer: "💬"
        case .question: "💡"
        case .contradiction: "⚠️"
        case .specification: "🛠"
        case .research: "🔍"
        case .decision: "📌"
        case .actionItem: "✅"
        case .risk: "🚨"
        }
    }
}

public enum Importance: Int, Codable, Comparable, Sendable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: Importance, rhs: Importance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AnalysisMode: String, Codable, Sendable {
    case fast
    case deep
}

public enum EvidenceKind: String, Codable, Sendable {
    case transcript
    case projectFile
    case sourceCode
    case gitHistory
    case web
    case screenContext
}

public struct EvidenceReference: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: EvidenceKind
    public let label: String
    public let location: String?
    public let line: Int?
    public let meetingTime: TimeInterval?
    public let regions: [ScreenNormalizedRect]?
    public let excerpt: String?
    public let checkedAt: Date

    public init(
        id: UUID = UUID(),
        kind: EvidenceKind,
        label: String,
        location: String? = nil,
        line: Int? = nil,
        meetingTime: TimeInterval? = nil,
        regions: [ScreenNormalizedRect] = [],
        excerpt: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.location = location
        self.line = line
        self.meetingTime = meetingTime
        self.regions = regions
        self.excerpt = excerpt
        self.checkedAt = checkedAt
    }
}

public struct SuggestionCard: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let sourceEventID: UUID
    public let topicRevision: Int
    public let category: SuggestionCategory
    public var title: String
    public var body: String
    public var importance: Importance
    public var confidence: Double
    public var evidence: [EvidenceReference]
    public let mode: AnalysisMode
    public let generatedAt: Date
    public var expiresAt: Date?
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        sourceEventID: UUID,
        topicRevision: Int,
        category: SuggestionCategory,
        title: String,
        body: String,
        importance: Importance,
        confidence: Double,
        evidence: [EvidenceReference],
        mode: AnalysisMode,
        generatedAt: Date = Date(),
        expiresAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sourceEventID = sourceEventID
        self.topicRevision = topicRevision
        self.category = category
        self.title = title
        self.body = body
        self.importance = importance
        self.confidence = max(0, min(confidence, 1))
        self.evidence = evidence
        self.mode = mode
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.isPinned = isPinned
    }
}

public struct MeetingTopic: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var revision: Int
    public var title: String
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int = 0,
        title: String = "会議開始",
        startedAt: Date = Date()
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.startedAt = startedAt
    }
}

public struct MeetingState: Codable, Hashable, Sendable {
    public let meetingID: UUID
    public var topic: MeetingTopic
    public var decisions: [String]
    public var questions: [String]
    public var requirements: [String]
    public var unresolvedIssues: [String]
    public var actionItems: [String]
    public var risks: [String]
    public var importantFacts: [String]
    public var currentScreenContext: String?
    public var revision: Int

    public init(meetingID: UUID) {
        self.meetingID = meetingID
        self.topic = MeetingTopic()
        self.decisions = []
        self.questions = []
        self.requirements = []
        self.unresolvedIssues = []
        self.actionItems = []
        self.risks = []
        self.importantFacts = []
        self.currentScreenContext = nil
        self.revision = 0
    }
}

public enum ProjectBriefItemKind: String, Codable, Sendable {
    case decision
    case actionItem
    case unresolvedIssue
    case requirement
    case risk
}

public struct ProjectBriefItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingStartedAt: Date
    public let kind: ProjectBriefItemKind
    public let text: String
    public let sourceSegmentID: UUID?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        meetingID: UUID,
        meetingTitle: String,
        meetingStartedAt: Date,
        kind: ProjectBriefItemKind,
        text: String,
        sourceSegmentID: UUID? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.kind = kind
        self.text = text
        self.sourceSegmentID = sourceSegmentID
    }
}

public struct ProjectTranscriptSearchHit: Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingStartedAt: Date
    public let segment: TranscriptSegment

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        meetingID: UUID,
        meetingTitle: String,
        meetingStartedAt: Date,
        segment: TranscriptSegment
    ) {
        self.id = id
        self.projectID = projectID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.segment = segment
    }
}

public struct ProjectSearchPolicy: Codable, Hashable, Sendable {
    public let rootPath: String
    public let additionalReferencePaths: [String]
    public let excludedPaths: [String]
    public let priorityFiles: [String]

    public init(project: ProjectConfiguration) {
        self.rootPath = project.rootPath
        self.additionalReferencePaths = project.additionalReferencePaths
        self.excludedPaths = project.excludedPaths
        self.priorityFiles = project.priorityFiles
    }

    public func normalizedAllowedPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let root = normalizedURL(for: rootPath, relativeTo: nil)
        let candidate = normalizedURL(for: path, relativeTo: root)
        let allowedRoots = [root] + additionalReferencePaths.map {
            normalizedURL(for: $0, relativeTo: root)
        }
        guard allowedRoots.contains(where: { contains(candidate, within: $0) })
        else { return nil }

        let exclusions = excludedPaths.map {
            normalizedURL(for: $0, relativeTo: root)
        }
        guard !exclusions.contains(where: { contains(candidate, within: $0) })
        else { return nil }
        return candidate.path
    }

    private func normalizedURL(for path: String, relativeTo root: URL?) -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(filePath: path)
        } else if let root {
            url = root.appending(path: path)
        } else {
            url = URL(filePath: path)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func contains(_ candidate: URL, within root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}

public struct MeetingContextEnvelope: Codable, Sendable {
    public let meetingID: UUID
    public let topic: MeetingTopic
    public let state: MeetingState
    public let recentTranscript: [TranscriptSegment]
    public let sourceEvent: DetectedEvent
    public let relatedEvidence: [EvidenceReference]
    public let projectSearchPolicy: ProjectSearchPolicy?
    public let projectBrief: [ProjectBriefItem]

    public init(
        meetingID: UUID,
        topic: MeetingTopic,
        state: MeetingState,
        recentTranscript: [TranscriptSegment],
        sourceEvent: DetectedEvent,
        relatedEvidence: [EvidenceReference],
        projectSearchPolicy: ProjectSearchPolicy? = nil,
        projectBrief: [ProjectBriefItem] = []
    ) {
        self.meetingID = meetingID
        self.topic = topic
        self.state = state
        self.recentTranscript = recentTranscript
        self.sourceEvent = sourceEvent
        self.relatedEvidence = relatedEvidence
        self.projectSearchPolicy = projectSearchPolicy
        self.projectBrief = projectBrief
    }
}

public struct MeetingReviewSnapshot: Identifiable, Codable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let finalTranscript: [TranscriptSegment]
    public let decisions: [String]
    public let questions: [String]
    public let requirements: [String]
    public let actionItems: [String]
    public let risks: [String]

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date,
        finalTranscript: [TranscriptSegment],
        decisions: [String],
        questions: [String],
        requirements: [String],
        actionItems: [String],
        risks: [String]
    ) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finalTranscript = finalTranscript
        self.decisions = decisions
        self.questions = questions
        self.requirements = requirements
        self.actionItems = actionItems
        self.risks = risks
    }
}
