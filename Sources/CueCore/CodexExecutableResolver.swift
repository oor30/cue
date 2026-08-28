import Foundation

public enum CodexExecutableSource: String, Sendable {
    case explicit = "CODEX_EXECUTABLE"
    case npmNative = "npm同梱ネイティブ"
    case nativeCLI = "ネイティブCLI"
    case chatGPTApp = "ChatGPT.app同梱"
    case codexApp = "Codex.app同梱"
}

public struct CodexExecutableResolution: Sendable {
    public let executableURL: URL
    public let source: CodexExecutableSource

    public init(executableURL: URL, source: CodexExecutableSource) {
        self.executableURL = executableURL
        self.source = source
    }

    public var displayDescription: String {
        "\(source.rawValue): \(executableURL.path)"
    }
}

public enum CodexExecutableResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationCandidates: [(URL, CodexExecutableSource)] = defaultApplicationCandidates
    ) -> CodexExecutableResolution? {
        var candidates: [(URL, CodexExecutableSource)] = []
        if let explicit = environment["CODEX_EXECUTABLE"], !explicit.isEmpty {
            candidates.append((URL(filePath: explicit), .explicit))
        }
        candidates.append(
            (
                homeDirectory.appending(path: ".local/bin/codex"),
                .nativeCLI
            )
        )
        candidates.append((URL(filePath: "/opt/homebrew/bin/codex"), .nativeCLI))
        candidates.append((URL(filePath: "/usr/local/bin/codex"), .nativeCLI))
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                (URL(filePath: String($0)).appending(path: "codex"), .nativeCLI)
            })
        }
        candidates.append(contentsOf: applicationCandidates)

        var visited: Set<String> = []
        for (candidate, source) in candidates {
            let key = candidate.standardizedFileURL.path
            guard visited.insert(key).inserted,
                  let resolution = resolveCandidate(candidate, source: source)
            else { continue }
            return resolution
        }
        return nil
    }

    public static let defaultApplicationCandidates: [(URL, CodexExecutableSource)] = [
        (
            URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            .chatGPTApp
        ),
        (
            URL(filePath: "/Applications/Codex.app/Contents/Resources/codex"),
            .codexApp
        )
    ]

    private static func resolveCandidate(
        _ candidate: URL,
        source: CodexExecutableSource
    ) -> CodexExecutableResolution? {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isScript(resolved) else {
            return CodexExecutableResolution(executableURL: resolved, source: source)
        }

        for nativeBinary in npmNativeCandidates(for: resolved) {
            if fileManager.isExecutableFile(atPath: nativeBinary.path),
               !isScript(nativeBinary) {
                return CodexExecutableResolution(
                    executableURL: nativeBinary.resolvingSymlinksInPath(),
                    source: .npmNative
                )
            }
        }
        return nil
    }

    private static func npmNativeCandidates(for script: URL) -> [URL] {
        let packageRoot = script
            .deletingLastPathComponent()
            .deletingLastPathComponent()

#if arch(arm64)
        let platformPackage = "codex-darwin-arm64"
        let target = "aarch64-apple-darwin"
#elseif arch(x86_64)
        let platformPackage = "codex-darwin-x64"
        let target = "x86_64-apple-darwin"
#else
        let platformPackage = ""
        let target = ""
#endif

        guard !platformPackage.isEmpty else { return [] }
        return [
            packageRoot
                .appending(path: "node_modules/@openai/\(platformPackage)")
                .appending(path: "vendor/\(target)/bin/codex"),
            packageRoot.appending(path: "vendor/\(target)/bin/codex")
        ]
    }

    private static func isScript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 2) else { return false }
        return prefix == Data("#!".utf8)
    }
}
