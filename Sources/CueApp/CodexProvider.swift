import Foundation
import CueCore

actor CodexProvider: AIProvider {
    nonisolated let capabilities = AIProviderCapabilities(
        supportsPersistentSessions: true,
        supportsCancellation: true,
        supportsWebSearch: true
    )

    private var client: CodexAppServerClient?
    private var clientWebSearchEnabled: Bool?
    private var executableResolution: CodexExecutableResolution?
    private var sessions: [AISessionHandle: ProjectConfiguration] = [:]
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTurns: [UUID: (threadID: String, turnID: String)] = [:]

    func startSession(
        project: ProjectConfiguration
    ) async throws -> AISessionHandle {
        let client = try await ensureClient(
            webSearchEnabled: project.webSearchEnabled
        )
        do {
            let threadID = try await client.startThread(
                cwd: project.rootPath,
                instructions: Self.developerInstructions(for: project)
            )
            let handle = AISessionHandle(id: threadID)
            sessions[handle] = project
            return handle
        } catch {
            await resetConnection()
            throw error
        }
    }

    func analyze(
        request: AnalysisRequest,
        in session: AISessionHandle
    ) async -> AsyncThrowingStream<AnalysisProgress, Error> {
        let client = self.client
        let project = sessions[session]

        return AsyncThrowingStream { continuation in
            guard let client, let project else {
                continuation.finish(throwing: CodexBridgeError.processNotRunning)
                return
            }

            let task = Task { [weak self] in
                do {
                    continuation.yield(.started(request.id))
                    let prompt = try Self.prompt(
                        for: request,
                        project: project
                    )
                    let turnID = try await client.startTurn(
                        threadID: session.id,
                        prompt: prompt,
                        outputSchema: Self.cardSchema
                    )
                    await self?.setActiveTurn(
                        analysisID: request.id,
                        threadID: session.id,
                        turnID: turnID
                    )
                    continuation.yield(.message("Codexで分析中"))

                    let completion: CodexTurnCompletion
                    do {
                        completion = try await Self.waitForTurn(
                            client: client,
                            turnID: turnID,
                            deadline: request.deadline
                        )
                    } catch {
                        await client.interrupt(
                            threadID: session.id,
                            turnID: turnID
                        )
                        throw error
                    }
                    let card = try Self.decodeCard(
                        completion.agentMessage,
                        request: request,
                        project: project
                    )
                    continuation.yield(.completed(card))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self?.analysisFinished(request.id)
            }
            analysisTasks[request.id] = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel(analysisID: UUID) async {
        analysisTasks.removeValue(forKey: analysisID)?.cancel()
        if let activeTurn = activeTurns.removeValue(forKey: analysisID),
           let client {
            await client.interrupt(
                threadID: activeTurn.threadID,
                turnID: activeTurn.turnID
            )
        }
    }

    func endSession(_ session: AISessionHandle) async {
        sessions.removeValue(forKey: session)
        if sessions.isEmpty {
            await client?.stop()
            client = nil
            clientWebSearchEnabled = nil
            executableResolution = nil
        }
    }

    func resetConnection() async {
        analysisTasks.values.forEach { $0.cancel() }
        analysisTasks.removeAll()
        if let client {
            for activeTurn in activeTurns.values {
                await client.interrupt(
                    threadID: activeTurn.threadID,
                    turnID: activeTurn.turnID
                )
            }
            await client.stop()
        }
        activeTurns.removeAll()
        sessions.removeAll()
        client = nil
        clientWebSearchEnabled = nil
        executableResolution = nil
    }

    func connectionDescription() -> String? {
        executableResolution?.displayDescription
    }

    func runningProcessCount() -> Int {
        client == nil ? 0 : 1
    }

    private func setActiveTurn(
        analysisID: UUID,
        threadID: String,
        turnID: String
    ) {
        activeTurns[analysisID] = (threadID, turnID)
    }

    private func analysisFinished(_ id: UUID) {
        analysisTasks.removeValue(forKey: id)
        activeTurns.removeValue(forKey: id)
    }

    private func ensureClient(
        webSearchEnabled: Bool
    ) async throws -> CodexAppServerClient {
        if let client,
           clientWebSearchEnabled == webSearchEnabled {
            return client
        }
        if client != nil {
            await resetConnection()
        }
        guard let resolution = CodexExecutableResolver.resolve() else {
            throw CodexBridgeError.executableNotFound
        }
        let newClient = CodexAppServerClient(
            executableURL: resolution.executableURL,
            webSearchEnabled: webSearchEnabled
        )
        try await newClient.start()
        client = newClient
        clientWebSearchEnabled = webSearchEnabled
        executableResolution = resolution
        return newClient
    }

    static func prompt(
        for request: AnalysisRequest,
        project: ProjectConfiguration
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let context = String(
            decoding: try encoder.encode(request.context),
            as: UTF8.self
        )

        let researchInstructions = project.webSearchEnabled
            ? """
              公開情報が回答に不可欠な場合だけWebを読み取り検索できます。
              Web上のフォーム送信、投稿、ログイン、購入その他の外部書き込みは禁止です。
              Webを根拠に使う場合は、httpまたはhttpsの直接URLをEvidenceに含めてください。
              """
            : "Web・MCP・外部サービスは使用しないでください。"

        let modeInstructions = request.mode == .deep
            ? """
              Deep分析としてProject Search Policyの許可範囲だけを調査してください。
              priorityFilesを先に確認し、関連箇所をrg等で絞り込み、主張には実在するファイルと行番号を付けてください。
              excludedPathsは読み取らないでください。
              """
            : """
              Fast分析として直近の発言を優先し、短時間で回答してください。
              Project調査は回答に不可欠な場合だけ最小限にしてください。
              """

        return """
        あなたはリアルタイムのCueです。セッションで指定されたProfileの役割と重点に従ってください。
        ファイル変更、コミット、外部への書き込みは一切行わないでください。
        次の会議イベントについて、今すぐ役立つ短い助言カードを1件だけ作成してください。
        triggerReasonが「手動操作:」で始まる場合は、その操作内容を最優先してください。
        deepモードではProject Root内の資料・ソース・Git履歴を読み取り調査し、根拠を付けてください。
        根拠が不足する場合は断定せず、確認すべき質問を提示してください。
        本文は日本語で4行以内にしてください。
        Meeting Context JSONのprojectBriefは同一Projectの過去会議から抽出した最大5件の参考情報です。
        過去の決定を現在も有効と断定せず、現在の発言と不一致なら仕様変更または確認事項として提示してください。

        \(modeInstructions)
        \(researchInstructions)

        分析モード: \(request.mode.rawValue)
        Meeting Context JSON:
        \(context)
        """
    }

    private static func waitForTurn(
        client: CodexAppServerClient,
        turnID: String,
        deadline: Duration
    ) async throws -> CodexTurnCompletion {
        try await withThrowingTaskGroup(of: CodexTurnCompletion.self) { group in
            group.addTask {
                try await client.waitForTurn(turnID)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw CodexBridgeError.timeout
            }

            guard let first = try await group.next() else {
                throw CodexBridgeError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    static func decodeCard(
        _ text: String,
        request: AnalysisRequest,
        project: ProjectConfiguration
    ) throws -> SuggestionCard {
        let data = Data(text.utf8)
        let payload: CardPayload
        do {
            payload = try JSONDecoder().decode(CardPayload.self, from: data)
        } catch {
            throw CodexBridgeError.invalidCard(error.localizedDescription)
        }

        let policy = ProjectSearchPolicy(project: project)
        let transcriptIDs = Set(
            request.context.recentTranscript.map { $0.id.uuidString }
                + request.context.relatedEvidence.compactMap {
                    $0.kind == .transcript ? $0.location : nil
                }
        )
        let screenEvidencePairs: [(String, EvidenceReference)] = request.context
            .relatedEvidence.compactMap { evidence in
                guard evidence.kind == .screenContext,
                      let location = evidence.location
                else { return nil }
                return (location, evidence)
            }
        let screenContextEvidence = Dictionary(
            screenEvidencePairs,
            uniquingKeysWith: { first, _ in first }
        )
        let evidence = payload.evidence.compactMap {
            validatedEvidence(
                $0,
                policy: policy,
                webSearchEnabled: project.webSearchEnabled,
                transcriptIDs: transcriptIDs,
                screenContextEvidence: screenContextEvidence
            )
        }
        let confidenceCap = evidence.isEmpty ? 0.6 : 0.95

        return SuggestionCard(
            meetingID: request.context.meetingID,
            sourceEventID: request.context.sourceEvent.id,
            topicRevision: request.context.topic.revision,
            category: payload.category,
            title: payload.title,
            body: payload.body,
            importance: payload.importance,
            confidence: min(payload.confidence, confidenceCap),
            evidence: evidence,
            mode: request.mode,
            expiresAt: request.context.sourceEvent.type == .question
                ? Date().addingTimeInterval(90)
                : nil
        )
    }

    private static func validatedEvidence(
        _ payload: EvidencePayload,
        policy: ProjectSearchPolicy,
        webSearchEnabled: Bool,
        transcriptIDs: Set<String>,
        screenContextEvidence: [String: EvidenceReference]
    ) -> EvidenceReference? {
        switch payload.kind {
        case .projectFile, .sourceCode:
            guard let location = payload.location,
                  let normalized = policy.normalizedAllowedPath(location)
            else { return nil }
            return EvidenceReference(
                kind: payload.kind,
                label: payload.label,
                location: normalized,
                line: payload.line.flatMap { $0 > 0 ? $0 : nil }
            )
        case .web:
            guard webSearchEnabled,
                  let location = payload.location,
                  let components = URLComponents(string: location),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = components.host,
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil,
                  isPublicWebHost(host)
            else { return nil }
            return EvidenceReference(
                kind: .web,
                label: payload.label,
                location: location,
                line: nil
            )
        case .transcript:
            guard let location = payload.location,
                  transcriptIDs.contains(location)
            else { return nil }
            return EvidenceReference(
                kind: .transcript,
                label: payload.label,
                location: location,
                line: nil
            )
        case .screenContext:
            guard let location = payload.location,
                  let evidence = screenContextEvidence[location]
            else { return nil }
            return evidence
        case .gitHistory:
            return EvidenceReference(
                kind: payload.kind,
                label: payload.label,
                location: payload.location,
                line: payload.line.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    private static func isPublicWebHost(_ host: String) -> Bool {
        let value = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".localhost") ||
            value.hasSuffix(".local") || (!value.contains(".") && !value.contains(":")) {
            return false
        }
        if value == "::" || value == "::1" || value.hasPrefix("fe8") ||
            value.hasPrefix("fe9") || value.hasPrefix("fea") ||
            value.hasPrefix("feb") || value.hasPrefix("fc") ||
            value.hasPrefix("fd") || value.hasPrefix("::ffff:") {
            return false
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) })
        else { return true }
        let first = parts[0]
        let second = parts[1]
        return !(first == 0 || first == 10 || first == 127 ||
            (first == 100 && (64...127).contains(second)) ||
            (first == 169 && second == 254) ||
            (first == 172 && (16...31).contains(second)) ||
            (first == 192 && second == 168) || first >= 224)
    }

    static func developerInstructions(
        for project: ProjectConfiguration
    ) -> String {
        let policy = ProjectSearchPolicy(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(policy)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
        let webPolicy = project.webSearchEnabled
            ? "公開Webは読み取り検索だけを許可し、外部サービスへの操作・送信は禁止します。"
            : "Web・MCP・外部サービスは使用しないでください。"
        let base = """
        Cueの読み取り専用分析セッションです。
        プロジェクト内外のファイル変更、apply_patch、Git変更、外部サービスへの書き込みを禁止します。
        読み取りは次のProject Search Policyの範囲に限定し、excludedPathsは読み取らないでください。
        コード・資料・Git履歴を読み取り調査し、重要な主張には根拠を付けてください。
        \(webPolicy)
        Project Search Policy JSON: \(encoded)
        """
        return PromptComposer().compose(base: base, project: project)
    }

    static let cardSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([
            .string("category"),
            .string("title"),
            .string("body"),
            .string("importance"),
            .string("confidence"),
            .string("evidence")
        ]),
        "properties": .object([
            "category": .object([
                "type": .string("string"),
                "enum": .array(SuggestionCategory.allCases.map { .string($0.rawValue) })
            ]),
            "title": .object(["type": .string("string")]),
            "body": .object(["type": .string("string")]),
            "importance": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("low"), .string("medium"),
                    .string("high"), .string("critical")
                ])
            ]),
            "confidence": .object([
                "type": .string("number"),
                "minimum": .number(0),
                "maximum": .number(1)
            ]),
            "evidence": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("kind"), .string("label"),
                        .string("location"), .string("line")
                    ]),
                    "properties": .object([
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("transcript"), .string("projectFile"),
                                .string("sourceCode"), .string("gitHistory"),
                                .string("web"), .string("screenContext")
                            ])
                        ]),
                        "label": .object(["type": .string("string")]),
                        "location": .object([
                            "type": .array([.string("string"), .string("null")])
                        ]),
                        "line": .object([
                            "type": .array([.string("integer"), .string("null")])
                        ])
                    ])
                ])
            ])
        ])
    ])
}

private struct CardPayload: Decodable {
    let category: SuggestionCategory
    let title: String
    let body: String
    let importance: Importance
    let confidence: Double
    let evidence: [EvidencePayload]

    enum CodingKeys: String, CodingKey {
        case category, title, body, importance, confidence, evidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(SuggestionCategory.self, forKey: .category)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        let importanceString = try container.decode(String.self, forKey: .importance)
        importance = switch importanceString {
        case "low": .low
        case "medium": .medium
        case "high": .high
        case "critical": .critical
        default: .medium
        }
        confidence = try container.decode(Double.self, forKey: .confidence)
        evidence = try container.decode([EvidencePayload].self, forKey: .evidence)
    }
}

private struct EvidencePayload: Decodable {
    let kind: EvidenceKind
    let label: String
    let location: String?
    let line: Int?
}
