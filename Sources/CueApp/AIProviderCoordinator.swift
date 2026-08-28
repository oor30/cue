import Foundation
import CueCore

actor AIProviderCoordinator: AIProvider {
    nonisolated let capabilities = AIProviderCapabilities(
        supportsPersistentSessions: false,
        supportsCancellation: true,
        supportsWebSearch: true
    )

    private enum Backend: Sendable {
        case codex
        case claudeCode
    }

    private struct RoutedSession: Sendable {
        let backend: Backend
        let providerHandle: AISessionHandle
    }

    private let codex = CodexProvider()
    private let claudeCode = ClaudeCodeProvider()
    private var sessions: [AISessionHandle: RoutedSession] = [:]
    private var latestBackend: Backend?

    func startSession(
        project: ProjectConfiguration
    ) async throws -> AISessionHandle {
        let backend: Backend
        let providerHandle: AISessionHandle
        switch project.provider {
        case .codex:
            backend = .codex
            providerHandle = try await codex.startSession(project: project)
        case .claudeCode:
            backend = .claudeCode
            providerHandle = try await claudeCode.startSession(project: project)
        }
        let handle = providerHandle
        sessions[handle] = RoutedSession(
            backend: backend,
            providerHandle: providerHandle
        )
        latestBackend = backend
        return handle
    }

    func analyze(
        request: AnalysisRequest,
        in session: AISessionHandle
    ) async -> AsyncThrowingStream<AnalysisProgress, Error> {
        guard let route = sessions[session] else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ClaudeCodeProviderError.unknownSession
                )
            }
        }
        switch route.backend {
        case .codex:
            return await codex.analyze(
                request: request,
                in: route.providerHandle
            )
        case .claudeCode:
            return await claudeCode.analyze(
                request: request,
                in: route.providerHandle
            )
        }
    }

    func cancel(analysisID: UUID) async {
        // analysisIDはProvider共通で一意。未担当側へのcancelはno-opになる。
        await codex.cancel(analysisID: analysisID)
        await claudeCode.cancel(analysisID: analysisID)
    }

    func endSession(_ session: AISessionHandle) async {
        guard let route = sessions.removeValue(forKey: session) else { return }
        switch route.backend {
        case .codex:
            await codex.endSession(route.providerHandle)
        case .claudeCode:
            await claudeCode.endSession(route.providerHandle)
        }
    }

    func resetConnection() async {
        sessions.removeAll()
        latestBackend = nil
        await codex.resetConnection()
        await claudeCode.resetConnection()
    }

    func connectionDescription() async -> String? {
        switch latestBackend {
        case .codex:
            await codex.connectionDescription()
        case .claudeCode:
            await claudeCode.connectionDescription()
        case nil:
            nil
        }
    }

    func runningProcessCount() async -> Int {
        await codex.runningProcessCount()
            + claudeCode.runningProcessCount()
    }
}
