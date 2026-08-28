import Foundation
import CueCore
import Testing

@Suite("ProjectSearchPolicyTests")
struct ProjectSearchPolicyTests {
    @Test
    func allowsConfiguredRootsAndRejectsExcludedOrTraversalPaths() {
        let project = ProjectConfiguration(
            name: "Test",
            rootPath: "/tmp/meeting-project",
            additionalReferencePaths: ["/tmp/shared-reference"],
            excludedPaths: ["Secrets", "build"]
        )
        let policy = ProjectSearchPolicy(project: project)

        #expect(
            policy.normalizedAllowedPath("Sources/App.swift") ==
                "/tmp/meeting-project/Sources/App.swift"
        )
        #expect(
            policy.normalizedAllowedPath("/tmp/shared-reference/spec.md") ==
                "/tmp/shared-reference/spec.md"
        )
        #expect(policy.normalizedAllowedPath("Secrets/token.txt") == nil)
        #expect(policy.normalizedAllowedPath("../outside.txt") == nil)
    }
}
