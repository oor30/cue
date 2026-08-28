import Foundation
import CueCore

enum ClaudeCodeProviderError: LocalizedError, Sendable {
    case executableNotFound
    case unknownSession
    case invalidProjectRoot
    case processLaunchFailed
    case notAuthenticated
    case processFailed(Int32)
    case invalidResponse
    case responseTooLarge
    case timeout

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Claude Code CLIが見つかりません。Claude CodeのインストールまたはCLAUDE_EXECUTABLEを確認してください。"
        case .unknownSession:
            "Claude Codeの分析セッションが見つかりません。"
        case .invalidProjectRoot:
            "Claude Codeが参照するProject Rootを開けません。"
        case .processLaunchFailed:
            "Claude Codeを起動できませんでした。"
        case .notAuthenticated:
            "Claude Codeにログインしていません。ターミナルで claude auth login を実行してください。"
        case .processFailed(let status):
            "Claude Code分析に失敗しました（終了コード: \(status)）。認証状態とCLI設定を確認してください。"
        case .invalidResponse:
            "Claude Codeから構造化された分析結果を取得できませんでした。"
        case .responseTooLarge:
            "Claude Codeの応答が許容サイズを超えました。"
        case .timeout:
            "Claude Code分析が制限時間を超えました。"
        }
    }
}

actor ClaudeCodeProvider: AIProvider {
    nonisolated let capabilities = AIProviderCapabilities(
        supportsPersistentSessions: false,
        supportsCancellation: true,
        supportsWebSearch: false
    )

    private final class ProcessBox: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    private final class FileHandleBox: @unchecked Sendable {
        let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
        }
    }

    private var executableResolution: ClaudeExecutableResolution?
    private var sessions: [AISessionHandle: ProjectConfiguration] = [:]
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var activeProcesses: [UUID: ProcessBox] = [:]

    func startSession(
        project: ProjectConfiguration
    ) async throws -> AISessionHandle {
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            throw ClaudeCodeProviderError.invalidProjectRoot
        }
        guard let resolution = ClaudeExecutableResolver.resolve() else {
            throw ClaudeCodeProviderError.executableNotFound
        }
        try await Self.validateAuthentication(
            executableURL: resolution.executableURL
        )
        executableResolution = resolution
        let handle = AISessionHandle(id: UUID().uuidString)
        sessions[handle] = project
        return handle
    }

    func analyze(
        request: AnalysisRequest,
        in session: AISessionHandle
    ) async -> AsyncThrowingStream<AnalysisProgress, Error> {
        guard let project = sessions[session],
              let resolution = executableResolution
        else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ClaudeCodeProviderError.unknownSession
                )
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    continuation.yield(.started(request.id))
                    continuation.yield(.message("Claude Codeで分析中"))
                    let card = try await self.execute(
                        request: request,
                        project: project,
                        executableURL: resolution.executableURL
                    )
                    try Task.checkCancellation()
                    continuation.yield(.completed(card))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.analysisFinished(request.id)
            }
            analysisTasks[request.id] = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancel(analysisID: UUID) async {
        activeProcesses.removeValue(forKey: analysisID)?.terminate()
        analysisTasks.removeValue(forKey: analysisID)?.cancel()
    }

    func endSession(_ session: AISessionHandle) async {
        sessions.removeValue(forKey: session)
        if sessions.isEmpty, activeProcesses.isEmpty {
            executableResolution = nil
        }
    }

    func resetConnection() async {
        analysisTasks.values.forEach { $0.cancel() }
        activeProcesses.values.forEach { $0.terminate() }
        analysisTasks.removeAll()
        activeProcesses.removeAll()
        sessions.removeAll()
        executableResolution = nil
    }

    func connectionDescription() -> String? {
        executableResolution?.displayDescription
    }

    func runningProcessCount() -> Int {
        activeProcesses.count
    }

    private func analysisFinished(_ id: UUID) {
        analysisTasks.removeValue(forKey: id)
        activeProcesses.removeValue(forKey: id)
        if sessions.isEmpty, activeProcesses.isEmpty {
            executableResolution = nil
        }
    }

    private func execute(
        request: AnalysisRequest,
        project: ProjectConfiguration,
        executableURL: URL
    ) async throws -> SuggestionCard {
        var safeProject = project
        safeProject.webSearchEnabled = false
        let prompt = try CodexProvider.prompt(
            for: request,
            project: safeProject
        )
        let schemaData = try JSONEncoder().encode(CodexProvider.cardSchema)
        let schema = String(decoding: schemaData, as: UTF8.self)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = URL(filePath: project.rootPath)
            .standardizedFileURL
        process.arguments = Self.arguments(
            project: safeProject,
            schema: schema
        )
        process.environment = Self.sanitizedEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let box = ProcessBox(process)
        do {
            try process.run()
        } catch {
            throw ClaudeCodeProviderError.processLaunchFailed
        }
        activeProcesses[request.id] = box

        let outputHandle = FileHandleBox(outputPipe.fileHandleForReading)
        let errorHandle = FileHandleBox(errorPipe.fileHandleForReading)
        let outputTask = Task.detached {
            try outputHandle.handle.readToEnd() ?? Data()
        }
        let errorTask = Task.detached {
            // stderrには認証情報や環境固有情報が含まれ得るため、必ず破棄する。
            _ = try errorHandle.handle.readToEnd()
        }

        do {
            try inputPipe.fileHandleForWriting.write(
                contentsOf: Data(prompt.utf8)
            )
            try inputPipe.fileHandleForWriting.close()
        } catch {
            box.terminate()
            throw ClaudeCodeProviderError.processLaunchFailed
        }

        let status: Int32
        do {
            status = try await Self.waitForTermination(
                box,
                deadline: request.deadline
            )
        } catch {
            box.terminate()
            outputTask.cancel()
            errorTask.cancel()
            activeProcesses.removeValue(forKey: request.id)
            throw error
        }
        activeProcesses.removeValue(forKey: request.id)
        let output = try await outputTask.value
        _ = await errorTask.result
        try Task.checkCancellation()
        guard status == 0 else {
            throw ClaudeCodeProviderError.processFailed(status)
        }
        guard output.count <= 4 * 1_024 * 1_024 else {
            throw ClaudeCodeProviderError.responseTooLarge
        }

        let cardJSON = try Self.extractStructuredOutput(output)
        return try CodexProvider.decodeCard(
            cardJSON,
            request: request,
            project: safeProject
        )
    }

    private static func arguments(
        project: ProjectConfiguration,
        schema: String
    ) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "json",
            "--json-schema", schema,
            "--permission-mode", "plan",
            "--safe-mode",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--no-chrome",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--tools", "Read,Glob,Grep",
            "--allowedTools", "Read,Glob,Grep",
            "--disallowedTools",
            "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,Skill,Chrome,Computer",
            "--system-prompt", CodexProvider.developerInstructions(for: project)
        ]
        for path in normalizedAdditionalReferencePaths(project) {
            arguments.append(contentsOf: ["--add-dir", path])
        }
        return arguments
    }

    private static func normalizedAdditionalReferencePaths(
        _ project: ProjectConfiguration
    ) -> [String] {
        let root = URL(filePath: project.rootPath).standardizedFileURL
        return project.additionalReferencePaths.compactMap { path in
            let url = path.hasPrefix("/")
                ? URL(filePath: path)
                : root.appending(path: path)
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: normalized.path)
            else { return nil }
            return normalized.path
        }
    }

    private static func waitForTermination(
        _ box: ProcessBox,
        deadline: Duration
    ) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    box.process.waitUntilExit()
                    return box.process.terminationStatus
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    box.terminate()
                    throw ClaudeCodeProviderError.timeout
                }
                guard let first = try await group.next() else {
                    box.terminate()
                    throw ClaudeCodeProviderError.timeout
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func validateAuthentication(
        executableURL: URL
    ) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["auth", "status", "--json"]
        process.environment = sanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = ProcessBox(process)
        do {
            try process.run()
        } catch {
            throw ClaudeCodeProviderError.processLaunchFailed
        }
        let status = try await waitForTermination(box, deadline: .seconds(5))
        guard status == 0 else {
            throw ClaudeCodeProviderError.notAuthenticated
        }
    }

    private static func extractStructuredOutput(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              root["is_error"] as? Bool != true
        else {
            throw ClaudeCodeProviderError.invalidResponse
        }

        if let structured = root["structured_output"],
           JSONSerialization.isValidJSONObject(structured) {
            let encoded = try JSONSerialization.data(withJSONObject: structured)
            return String(decoding: encoded, as: UTF8.self)
        }
        if let result = root["result"] as? String {
            return stripCodeFence(result)
        }
        if let result = root["result"],
           JSONSerialization.isValidJSONObject(result) {
            let encoded = try JSONSerialization.data(withJSONObject: result)
            return String(decoding: encoded, as: UTF8.self)
        }
        throw ClaudeCodeProviderError.invalidResponse
    }

    private static func stripCodeFence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitizedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowedExact = [
            "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "TERM", "SSL_CERT_FILE", "SSL_CERT_DIR"
        ]
        var result = allowedExact.reduce(into: [String: String]()) {
            if let value = source[$1] { $0[$1] = value }
        }
        for (key, value) in source where
            key.hasPrefix("ANTHROPIC_") ||
            key.hasPrefix("CLAUDE_CODE_") ||
            key.hasPrefix("AWS_") ||
            key.hasPrefix("GOOGLE_") {
            result[key] = value
        }
        return result
    }
}
