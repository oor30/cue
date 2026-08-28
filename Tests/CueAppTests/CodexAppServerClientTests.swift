import Foundation
import CueCore
import Testing
@testable import CueApp

@Suite("CodexAppServerClientTests", .serialized)
struct CodexAppServerClientTests {
    @Test
    func receivesInitializeAndThreadStartResponsesWithoutBlocking() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-app-server-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let server = temporary.appending(path: "fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r thread_start
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"fake-thread"}}}'
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: server)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let client = CodexAppServerClient(
            executableURL: server,
            codexHomeOverride: temporary.appending(path: "codex-home")
        )
        try await client.start()
        let threadID = try await client.startThread(
            cwd: temporary.path,
            instructions: "read only"
        )
        #expect(threadID == "fake-thread")
        await client.stop()
    }

    @Test
    func sendsReadOnlyPolicyForThreadAndEveryTurn() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-readonly-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let capture = temporary.appending(path: "requests.jsonl")
        let server = temporary.appending(path: "fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r thread_start
        printf '%s\n' "$thread_start" >> "\(capture.path)"
        printf '%s\n' '{"id":2,"result":{"thread":{"id":"fake-thread"}}}'
        IFS= read -r turn_start
        printf '%s\n' "$turn_start" >> "\(capture.path)"
        printf '%s\n' '{"id":3,"result":{"turn":{"id":"fake-turn"}}}'
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: server)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let client = CodexAppServerClient(
            executableURL: server,
            codexHomeOverride: temporary.appending(path: "codex-home")
        )
        try await client.start()
        let threadID = try await client.startThread(
            cwd: temporary.path,
            instructions: "read only"
        )
        _ = try await client.startTurn(
            threadID: threadID,
            prompt: "このファイルを書き換えて。git commitして。",
            outputSchema: .object([:])
        )
        await client.stop()

        let lines = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        let thread = try decoder.decode(JSONValue.self, from: Data(lines[0].utf8))
        let turn = try decoder.decode(JSONValue.self, from: Data(lines[1].utf8))
        #expect(thread["params"]?["sandbox"]?.stringValue == "read-only")
        #expect(thread["params"]?["approvalPolicy"]?.stringValue == "never")
        #expect(turn["params"]?["sandboxPolicy"]?["type"]?.stringValue == "readOnly")
        #expect(turn["params"]?["approvalPolicy"]?.stringValue == "never")
    }

    @Test
    func timesOutAnUnresponsiveServerWithoutBlockingTheApp() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-timeout-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let server = temporary.appending(path: "fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r thread_start
        sleep 2
        """
        try Data(script.utf8).write(to: server)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let client = CodexAppServerClient(
            executableURL: server,
            codexHomeOverride: temporary.appending(path: "codex-home"),
            requestTimeout: .milliseconds(500)
        )
        try await client.start()
        do {
            _ = try await client.startThread(
                cwd: temporary.path,
                instructions: "read only"
            )
            Issue.record("応答停止したサーバーがタイムアウトしませんでした。")
        } catch let error as CodexBridgeError {
            guard case .requestTimeout("thread/start") = error else {
                Issue.record("想定外のエラー: \(error)")
                await client.stop()
                return
            }
        }
        await client.stop()
    }

    @Test
    func failsAnActiveTurnPromptlyWhenTheProcessExits() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-process-exit-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let server = temporary.appending(path: "fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r thread_start
        printf '%s\n' '{"id":2,"result":{"thread":{"id":"fake-thread"}}}'
        IFS= read -r turn_start
        printf '%s\n' '{"id":3,"result":{"turn":{"id":"fake-turn"}}}'
        exit 9
        """
        try Data(script.utf8).write(to: server)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let client = CodexAppServerClient(
            executableURL: server,
            codexHomeOverride: temporary.appending(path: "codex-home"),
            requestTimeout: .seconds(1)
        )
        try await client.start()
        let threadID = try await client.startThread(
            cwd: temporary.path,
            instructions: "read only"
        )
        do {
            let turnID = try await client.startTurn(
                threadID: threadID,
                prompt: "分析してください。",
                outputSchema: .object([:])
            )
            _ = try await client.waitForTurn(turnID)
            Issue.record("プロセス終了後も分析が成功扱いになりました。")
        } catch {
            #expect(error is CodexBridgeError)
        }
        await client.stop()
    }

    @Test
    func sendsTurnInterruptWhenAnalysisIsCancelled() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-interrupt-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let capture = temporary.appending(path: "interrupt.jsonl")
        let server = temporary.appending(path: "fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r thread_start
        printf '%s\n' '{"id":2,"result":{"thread":{"id":"fake-thread"}}}'
        IFS= read -r turn_start
        printf '%s\n' '{"id":3,"result":{"turn":{"id":"fake-turn"}}}'
        IFS= read -r interrupt
        printf '%s\n' "$interrupt" >> "\(capture.path)"
        printf '%s\n' '{"id":4,"result":{}}'
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: server)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let client = CodexAppServerClient(
            executableURL: server,
            codexHomeOverride: temporary.appending(path: "codex-home")
        )
        try await client.start()
        let threadID = try await client.startThread(
            cwd: temporary.path,
            instructions: "read only"
        )
        let turnID = try await client.startTurn(
            threadID: threadID,
            prompt: "長時間分析してください。",
            outputSchema: .object([:])
        )
        await client.interrupt(threadID: threadID, turnID: turnID)
        await client.stop()

        let message = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: capture)
        )
        #expect(message["method"]?.stringValue == "turn/interrupt")
        #expect(message["params"]?["threadId"]?.stringValue == "fake-thread")
        #expect(message["params"]?["turnId"]?.stringValue == "fake-turn")
    }

    @Test
    func rejectsInvalidCardJSON() throws {
        let meetingID = UUID()
        let state = MeetingState(meetingID: meetingID)
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 1,
            text: "確認できますか？",
            isFinal: true
        )
        let event = DetectedEvent(
            meetingID: meetingID,
            topicID: state.topic.id,
            topicRevision: state.topic.revision,
            type: .question,
            sourceSegmentIDs: [segment.id],
            triggerReason: "テスト",
            excerpt: segment.text,
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
            deadline: .seconds(1)
        )
        let project = ProjectConfiguration(name: "Test", rootPath: "/tmp")

        do {
            _ = try CodexProvider.decodeCard(
                "これはJSONではありません",
                request: request,
                project: project
            )
            Issue.record("不正JSONがカードとして受理されました。")
        } catch let error as CodexBridgeError {
            guard case .invalidCard = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
    }
}
