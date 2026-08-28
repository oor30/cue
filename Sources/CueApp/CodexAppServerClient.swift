import Foundation

enum CodexBridgeError: LocalizedError, Sendable {
    case executableNotFound
    case processNotRunning
    case processExited(String)
    case invalidMessage
    case protocolError(String)
    case turnFailed(String)
    case missingAgentMessage
    case invalidCard(String)
    case timeout
    case requestTimeout(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "利用可能なネイティブCodexが見つかりません。CodexまたはChatGPTアプリ、Codex CLIを確認してください。"
        case .processNotRunning:
            "Codex app-serverが起動していません。"
        case .processExited(let detail):
            "Codex app-serverが起動直後に終了しました。\n\(detail)"
        case .invalidMessage:
            "Codexから不正なメッセージを受信しました。"
        case .protocolError(let message):
            "Codexプロトコルエラー: \(message)"
        case .turnFailed(let message):
            "Codex分析に失敗しました: \(message)"
        case .missingAgentMessage:
            "Codexの最終回答を取得できませんでした。"
        case .invalidCard(let message):
            "Codexカードを読み取れません: \(message)"
        case .timeout:
            "Codex分析が制限時間を超えました。"
        case .requestTimeout(let method):
            "Codexから制限時間内に応答がありませんでした（\(method)）。"
        }
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw CodexBridgeError.invalidMessage
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

struct CodexTurnCompletion: Sendable {
    let threadID: String
    let turnID: String
    let agentMessage: String
}

actor CodexAppServerClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    private let executableURL: URL
    private let codexHomeOverride: URL?
    private let requestTimeout: Duration
    private let webSearchEnabled: Bool
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var errorContinuation: AsyncStream<Data>.Continuation?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var requestTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var turnWaiters: [String: CheckedContinuation<CodexTurnCompletion, Error>] = [:]
    private var completedTurns: [String: Result<CodexTurnCompletion, Error>] = [:]
    private var activeTurnIDs: Set<String> = []
    private var terminalError: CodexBridgeError?
    private var standardErrorLines: [String] = []

    init(
        executableURL: URL,
        codexHomeOverride: URL? = nil,
        requestTimeout: Duration = .seconds(10),
        webSearchEnabled: Bool = false
    ) {
        self.executableURL = executableURL
        self.codexHomeOverride = codexHomeOverride
        self.requestTimeout = requestTimeout
        self.webSearchEnabled = webSearchEnabled
    }

    func start() async throws {
        guard process == nil else { return }
        standardErrorLines = []
        terminalError = nil

        let safeCodexHome: URL
        if let codexHomeOverride {
            try FileManager.default.createDirectory(
                at: codexHomeOverride,
                withIntermediateDirectories: true
            )
            safeCodexHome = codexHomeOverride
        } else {
            safeCodexHome = try Self.prepareSafeCodexHome()
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        var arguments = [
            "app-server",
            "--listen", "stdio://",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "--disable", "in_app_browser"
        ]
        if !webSearchEnabled {
            arguments.append(contentsOf: ["--disable", "browser_use"])
        }
        process.arguments = arguments
        process.environment = Self.sanitizedEnvironment(codexHome: safeCodexHome)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CodexBridgeError.processExited(error.localizedDescription)
        }

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting

        let output = outputPipe.fileHandleForReading
        outputHandle = output
        let outputStream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        outputContinuation = outputStream.continuation
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputStream.continuation.finish()
            } else {
                outputStream.continuation.yield(data)
            }
        }
        outputTask = Task { [weak self] in
            for await data in outputStream.stream {
                guard !Task.isCancelled else { return }
                await self?.receiveOutputChunk(data)
            }
            await self?.flushOutputBuffer()
            await self?.processEnded(reason: "Codex app-serverが終了しました。")
        }

        let errorOutput = errorPipe.fileHandleForReading
        errorHandle = errorOutput
        let errorStream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        errorContinuation = errorStream.continuation
        errorOutput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorStream.continuation.finish()
            } else {
                errorStream.continuation.yield(data)
            }
        }
        errorTask = Task { [weak self] in
            for await data in errorStream.stream {
                guard !Task.isCancelled else { return }
                await self?.receiveErrorChunk(data)
            }
            await self?.flushErrorBuffer()
        }

        try await Task.sleep(for: .milliseconds(100))
        guard process.isRunning else {
            let detail = standardErrorSummary(
                defaultMessage: "終了コード: \(process.terminationStatus)"
            )
            closeIO()
            self.process = nil
            throw CodexBridgeError.processExited(detail)
        }

        do {
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("meeting_copilot"),
                        "title": .string("Cue"),
                        "version": .string("0.1.0")
                    ]),
                    "capabilities": .object([:])
                ])
            )
            try sendNotification(method: "initialized", params: nil)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        closeIO()
        process?.terminate()
        process = nil
        processEnded(reason: "Codex app-serverを停止しました。")
    }

    func startThread(
        cwd: String,
        instructions: String
    ) async throws -> String {
        let response = try await request(
            method: "thread/start",
            params: .object([
                "cwd": .string(cwd),
                "sandbox": .string("read-only"),
                "approvalPolicy": .string("never"),
                "developerInstructions": .string(instructions),
                "serviceName": .string("Cue")
            ])
        )
        guard let id = response["thread"]?["id"]?.stringValue else {
            throw CodexBridgeError.invalidMessage
        }
        return id
    }

    func startTurn(
        threadID: String,
        prompt: String,
        outputSchema: JSONValue
    ) async throws -> String {
        let response = try await request(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(prompt)
                    ])
                ]),
                "outputSchema": outputSchema,
                "sandboxPolicy": .object([
                    "type": .string("readOnly")
                ]),
                "approvalPolicy": .string("never")
            ])
        )
        guard let turnID = response["turn"]?["id"]?.stringValue else {
            throw CodexBridgeError.invalidMessage
        }
        if let terminalError {
            throw terminalError
        }
        activeTurnIDs.insert(turnID)
        return turnID
    }

    func waitForTurn(_ turnID: String) async throws -> CodexTurnCompletion {
        if let completed = completedTurns.removeValue(forKey: turnID) {
            activeTurnIDs.remove(turnID)
            return try completed.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                turnWaiters[turnID] = continuation
            }
        } onCancel: {
            Task { await self.cancelTurnWaiter(turnID) }
        }
    }

    func interrupt(threadID: String, turnID: String) async {
        _ = try? await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    private func request(
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        guard process?.isRunning == true else {
            throw CodexBridgeError.processExited(
                standardErrorSummary(defaultMessage: "プロセスが停止しています。")
            )
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let message = JSONValue.object([
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": params
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(continuation: continuation)
            do {
                try send(message)
                let timeout = requestTimeout
                requestTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutRequest(requestID, method: method)
                }
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(
        method: String,
        params: JSONValue?
    ) throws {
        var fields: [String: JSONValue] = ["method": .string(method)]
        if let params { fields["params"] = params }
        try send(.object(fields))
    }

    private func send(_ message: JSONValue) throws {
        guard let inputHandle else {
            throw CodexBridgeError.processNotRunning
        }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }

        if let requestID = message["id"].flatMap(Self.integerValue),
           message["method"] == nil {
            guard let pending = pendingRequests.removeValue(forKey: requestID) else {
                return
            }
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            if let errorMessage = message["error"]?["message"]?.stringValue {
                pending.continuation.resume(
                    throwing: CodexBridgeError.protocolError(errorMessage)
                )
            } else if let result = message["result"] {
                pending.continuation.resume(returning: result)
            } else {
                pending.continuation.resume(throwing: CodexBridgeError.invalidMessage)
            }
            return
        }

        guard let method = message["method"]?.stringValue,
              let params = message["params"]
        else { return }

        if message["id"] != nil {
            denyServerRequest(message)
            return
        }

        switch method {
        case "turn/completed":
            handleTurnCompleted(params)
        default:
            break
        }
    }

    private func handleTurnCompleted(_ params: JSONValue) {
        guard let threadID = params["threadId"]?.stringValue,
              let turn = params["turn"],
              let turnID = turn["id"]?.stringValue
        else { return }

        let status = turn["status"]?.stringValue ?? "unknown"
        activeTurnIDs.remove(turnID)
        let result: Result<CodexTurnCompletion, Error>
        if status == "completed" {
            let messages = turn["items"]?.arrayValue?.compactMap { item -> String? in
                guard item["type"]?.stringValue == "agentMessage" else { return nil }
                return item["text"]?.stringValue
            } ?? []
            if let message = messages.last {
                result = .success(
                    CodexTurnCompletion(
                        threadID: threadID,
                        turnID: turnID,
                        agentMessage: message
                    )
                )
            } else {
                result = .failure(CodexBridgeError.missingAgentMessage)
            }
        } else {
            let message = turn["error"]?["message"]?.stringValue ?? status
            result = .failure(CodexBridgeError.turnFailed(message))
        }

        if let waiter = turnWaiters.removeValue(forKey: turnID) {
            waiter.resume(with: result)
        } else {
            completedTurns[turnID] = result
        }
    }

    private func denyServerRequest(_ message: JSONValue) {
        guard let id = message["id"] else { return }
        let response = JSONValue.object([
            "id": id,
            "result": .object(["decision": .string("denied")])
        ])
        try? send(response)
    }

    private func processEnded(reason: String) {
        let detail = standardErrorSummary(defaultMessage: reason)
        let error = CodexBridgeError.protocolError(detail)
        terminalError = error
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        for request in pending {
            request.continuation.resume(throwing: error)
        }
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        for turnID in activeTurnIDs {
            completedTurns[turnID] = .failure(error)
        }
        activeTurnIDs.removeAll()
    }

    private func cancelTurnWaiter(_ turnID: String) {
        activeTurnIDs.remove(turnID)
        turnWaiters.removeValue(forKey: turnID)?.resume(
            throwing: CancellationError()
        )
    }

    private func timeoutRequest(_ requestID: Int, method: String) {
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        pendingRequests.removeValue(forKey: requestID)?.continuation.resume(
            throwing: CodexBridgeError.requestTimeout(method)
        )
    }

    private func receiveOutputChunk(_ data: Data) {
        outputBuffer.append(data)
        for line in extractLines(from: &outputBuffer) {
            receive(line)
        }
    }

    private func receiveErrorChunk(_ data: Data) {
        errorBuffer.append(data)
        for line in extractLines(from: &errorBuffer) {
            recordStandardError(String(decoding: line, as: UTF8.self))
        }
    }

    private func flushOutputBuffer() {
        guard !outputBuffer.isEmpty else { return }
        let data = outputBuffer
        outputBuffer.removeAll(keepingCapacity: false)
        receive(data)
    }

    private func flushErrorBuffer() {
        guard !errorBuffer.isEmpty else { return }
        let line = String(decoding: errorBuffer, as: UTF8.self)
        errorBuffer.removeAll(keepingCapacity: false)
        recordStandardError(line)
    }

    private func extractLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        return lines
    }

    private func closeIO() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputContinuation?.finish()
        errorContinuation?.finish()
        outputContinuation = nil
        errorContinuation = nil
        outputTask?.cancel()
        errorTask?.cancel()
        outputTask = nil
        errorTask = nil
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        inputHandle?.closeFile()
        inputHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
    }

    private func recordStandardError(_ line: String) {
        let trimmed = String(line.prefix(1_000))
        guard !trimmed.isEmpty else { return }
        standardErrorLines.append(trimmed)
        if standardErrorLines.count > 12 {
            standardErrorLines.removeFirst(standardErrorLines.count - 12)
        }
    }

    private func standardErrorSummary(defaultMessage: String) -> String {
        guard !standardErrorLines.isEmpty else { return defaultMessage }
        return standardErrorLines.joined(separator: "\n")
    }

    private static func integerValue(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(number)
    }

    private static func sanitizedEnvironment(codexHome: URL) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = [
            "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "TERM", "SSL_CERT_FILE"
        ]
        var environment = allowed.reduce(into: [:]) { result, key in
            result[key] = source[key]
        }
        environment["CODEX_HOME"] = codexHome.path
        return environment
    }

    private static func prepareSafeCodexHome() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let safeHome = applicationSupport
            .appending(path: "Cue", directoryHint: .isDirectory)
            .appending(path: "CodexSafeHome", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: safeHome,
            withIntermediateDirectories: true
        )

        let originalCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(filePath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
        let sourceAuth = originalCodexHome.appending(path: "auth.json")
        let safeAuth = safeHome.appending(path: "auth.json")
        if fileManager.fileExists(atPath: sourceAuth.path),
           !fileManager.fileExists(atPath: safeAuth.path) {
            try fileManager.createSymbolicLink(
                at: safeAuth,
                withDestinationURL: sourceAuth
            )
        }

        let config = safeHome.appending(path: "config.toml")
        let safeConfiguration = """
        sandbox_mode = "read-only"
        approval_policy = "never"
        suppress_unstable_features_warning = true
        """
        try Data(safeConfiguration.utf8).write(to: config, options: .atomic)
        return safeHome
    }
}
