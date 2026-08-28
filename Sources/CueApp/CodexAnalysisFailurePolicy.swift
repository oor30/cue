import Foundation

enum CodexAnalysisFailurePolicy {
    static func isDeadlineExceeded(_ error: any Error) -> Bool {
        guard let error = error as? CodexBridgeError else { return false }
        if case .timeout = error { return true }
        return false
    }

    static func shouldReconnect(_ error: any Error) -> Bool {
        guard let error = error as? CodexBridgeError else { return false }
        switch error {
        case .processNotRunning, .processExited, .protocolError:
            return true
        case .executableNotFound, .invalidMessage, .turnFailed,
             .missingAgentMessage, .invalidCard, .timeout, .requestTimeout:
            return false
        }
    }
}
