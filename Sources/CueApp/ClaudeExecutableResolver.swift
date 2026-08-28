import Foundation

enum ClaudeExecutableSource: String, Sendable {
    case explicit = "CLAUDE_EXECUTABLE"
    case nativeCLI = "Claude Code CLI"
}

struct ClaudeExecutableResolution: Sendable {
    let executableURL: URL
    let source: ClaudeExecutableSource

    var displayDescription: String {
        "\(source.rawValue): \(executableURL.path)"
    }
}

enum ClaudeExecutableResolver {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeExecutableResolution? {
        var candidates: [(URL, ClaudeExecutableSource)] = []
        if let explicit = environment["CLAUDE_EXECUTABLE"],
           !explicit.isEmpty {
            candidates.append((URL(filePath: explicit), .explicit))
        }
        candidates.append((
            homeDirectory.appending(path: ".local/bin/claude"),
            .nativeCLI
        ))
        candidates.append((URL(filePath: "/opt/homebrew/bin/claude"), .nativeCLI))
        candidates.append((URL(filePath: "/usr/local/bin/claude"), .nativeCLI))
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                (
                    URL(filePath: String($0)).appending(path: "claude"),
                    .nativeCLI
                )
            })
        }

        var visited: Set<String> = []
        for (candidate, source) in candidates {
            let standardized = candidate.standardizedFileURL
            guard visited.insert(standardized.path).inserted,
                  FileManager.default.isExecutableFile(atPath: standardized.path)
            else { continue }
            return ClaudeExecutableResolution(
                executableURL: standardized.resolvingSymlinksInPath(),
                source: source
            )
        }
        return nil
    }
}
