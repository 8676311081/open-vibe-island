import Foundation
import OpenIslandCore
import os

/// Owns the lifecycle of `LLMProxyServer` from the app side. Kept tiny on
/// purpose — the server is in Core, the UI surfaces are in Views, this is
/// just the wire between them.
@MainActor
final class LLMProxyCoordinator {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMProxyCoordinator")

    private let server: LLMProxyServer
    private(set) var isRunning = false

    var port: UInt16 { server.configuration.port }

    init(configuration: LLMProxyConfiguration = .default) {
        self.server = LLMProxyServer(configuration: configuration)
    }

    func start() {
        guard !isRunning else { return }
        do {
            try server.start()
            isRunning = true
            Self.logger.info("LLM proxy started on port \(self.server.configuration.port)")
        } catch {
            Self.logger.error("LLM proxy failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        server.stop()
        isRunning = false
    }
}
