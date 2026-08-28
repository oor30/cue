import Foundation

public struct AIProviderCapabilities: Sendable {
    public let supportsPersistentSessions: Bool
    public let supportsCancellation: Bool
    public let supportsWebSearch: Bool

    public init(
        supportsPersistentSessions: Bool,
        supportsCancellation: Bool,
        supportsWebSearch: Bool
    ) {
        self.supportsPersistentSessions = supportsPersistentSessions
        self.supportsCancellation = supportsCancellation
        self.supportsWebSearch = supportsWebSearch
    }
}

public struct AISessionHandle: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct AnalysisRequest: Sendable {
    public let id: UUID
    public let mode: AnalysisMode
    public let context: MeetingContextEnvelope
    public let deadline: Duration

    public init(
        id: UUID = UUID(),
        mode: AnalysisMode,
        context: MeetingContextEnvelope,
        deadline: Duration
    ) {
        self.id = id
        self.mode = mode
        self.context = context
        self.deadline = deadline
    }
}

public enum AnalysisProgress: Sendable {
    case started(UUID)
    case message(String)
    case completed(SuggestionCard)
}

public protocol AIProvider: Sendable {
    var capabilities: AIProviderCapabilities { get }

    func startSession(project: ProjectConfiguration) async throws -> AISessionHandle
    func analyze(
        request: AnalysisRequest,
        in session: AISessionHandle
    ) async -> AsyncThrowingStream<AnalysisProgress, Error>
    func cancel(analysisID: UUID) async
    func endSession(_ session: AISessionHandle) async
}

public struct LocalSuggestionFactory: Sendable {
    public init() {}

    public func card(
        for event: DetectedEvent,
        segment: TranscriptSegment
    ) -> SuggestionCard {
        let category: SuggestionCategory
        let title: String
        let body: String
        let importance: Importance

        switch event.type {
        case .question:
            category = .answer
            title = "回答準備"
            body = "回答前に『対象範囲はどこまでか』『既存仕様のどれを正とするか』を確認してください。"
            importance = .high
        case .requirement:
            category = .question
            title = "要件の確認推奨"
            body = "次に『誰が使いますか』『権限差はありますか』『完了条件を一文でどう定義しますか』と確認してください。"
            importance = .high
        case .decision:
            category = .decision
            title = "決定事項候補"
            body = event.excerpt
            importance = .medium
        case .actionItem:
            category = .actionItem
            title = "TODO候補"
            body = event.excerpt
            importance = .medium
        case .risk:
            category = .risk
            title = "リスク確認"
            body = "次に『失敗時の影響範囲は』『回避策と追加工数は』『判断期限はいつですか』と確認してください。"
            importance = .high
        case .importantFact:
            category = .research
            title = "重要情報"
            body = event.excerpt
            importance = .medium
        case .specificationChange:
            category = .specification
            title = "仕様変更候補"
            body = "次に『以前の決定を上書きしますか』『影響する画面・データ・期限は』『移行対応は必要ですか』と確認してください。"
            importance = .high
        case .contradiction:
            category = .contradiction
            title = "矛盾の可能性"
            body = "次に『どちらを正としますか』『最終判断者は誰ですか』『いつまでに確定しますか』と確認してください。"
            importance = .critical
        case .stalledDiscussion:
            category = .question
            title = "持ち越し条件を確認"
            body = "次に『未決定なのは何ですか』『判断材料・担当者・回答期限を決められますか』と確認してください。"
            importance = .high
        }

        let evidence = EvidenceReference(
            kind: .transcript,
            label: "会議発言",
            location: segment.id.uuidString
        )

        let confidence = min(0.95, event.localScore * 0.8 + 0.1)
        return SuggestionCard(
            meetingID: event.meetingID,
            sourceEventID: event.id,
            topicRevision: event.topicRevision,
            category: category,
            title: title,
            body: body,
            importance: importance,
            confidence: confidence,
            evidence: [evidence],
            mode: .fast,
            expiresAt: event.type == .question
                ? Date().addingTimeInterval(90)
                : nil
        )
    }
}
