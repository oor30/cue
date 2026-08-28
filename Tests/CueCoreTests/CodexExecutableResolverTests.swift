import Foundation
import CueCore
import Testing

@Suite("CodexExecutableResolverTests")
struct CodexExecutableResolverTests {
    @Test
    func resolvesNPMWrapperToBundledNativeBinary() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-resolver-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        let packageRoot = temporary
            .appending(path: ".local/lib/node_modules/@openai/codex")
        let script = packageRoot.appending(path: "bin/codex.js")
#if arch(arm64)
        let native = packageRoot.appending(
            path: "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        )
#else
        let native = packageRoot.appending(
            path: "node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        )
#endif
        let wrapper = temporary.appending(path: ".local/bin/codex")

        try fileManager.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: native.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env node\n".utf8).write(to: script)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: native)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: native.path
        )
        try fileManager.createSymbolicLink(at: wrapper, withDestinationURL: script)

        let result = CodexExecutableResolver.resolve(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: temporary,
            applicationCandidates: []
        )

        #expect(result?.source == .npmNative)
        #expect(result?.executableURL.path == native.path)
    }

    @Test
    func ignoresNodeScriptWithoutBundledNativeBinary() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appending(path: "cue-resolver-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        let wrapper = temporary.appending(path: ".local/bin/codex")
        try fileManager.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env node\n".utf8).write(to: wrapper)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )

        let result = CodexExecutableResolver.resolve(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: temporary,
            applicationCandidates: []
        )

        #expect(result == nil)
    }
}
