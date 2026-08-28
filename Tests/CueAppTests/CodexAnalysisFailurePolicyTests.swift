import Testing
@testable import CueApp

@Suite("CodexAnalysisFailurePolicyTests")
struct CodexAnalysisFailurePolicyTests {
    @Test func keepsTheConnectionForAnalysisDeadlineAndContentErrors() {
        #expect(
            CodexAnalysisFailurePolicy.isDeadlineExceeded(
                CodexBridgeError.timeout
            )
        )
        #expect(
            !CodexAnalysisFailurePolicy.shouldReconnect(
                CodexBridgeError.timeout
            )
        )
        #expect(
            !CodexAnalysisFailurePolicy.shouldReconnect(
                CodexBridgeError.invalidCard("invalid")
            )
        )
    }

    @Test func reconnectsOnlyForConnectionLevelFailures() {
        #expect(
            CodexAnalysisFailurePolicy.shouldReconnect(
                CodexBridgeError.processNotRunning
            )
        )
        #expect(
            CodexAnalysisFailurePolicy.shouldReconnect(
                CodexBridgeError.processExited("terminated")
            )
        )
        #expect(
            CodexAnalysisFailurePolicy.shouldReconnect(
                CodexBridgeError.protocolError("broken stream")
            )
        )
    }
}
