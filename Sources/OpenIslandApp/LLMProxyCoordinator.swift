import Foundation
import OpenIslandCore
import os

/// Owns the lifecycle of `LLMProxyServer` from the app side, plus the
/// stats store + usage observer that live alongside it. Kept tiny on
/// purpose — server, store, and observer are all in Core, the UI
/// surfaces are in Views, this is just the wire between them.
@MainActor
final class LLMProxyCoordinator {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMProxyCoordinator")
    static let portDefaultsKey = "OpenIsland.LLMProxy.port"
    static let openAIUpstreamDefaultsKey = "OpenIsland.LLMProxy.openAIUpstream"
    static let anthropicUpstreamDefaultsKey = "OpenIsland.LLMProxy.anthropicUpstream"
    static let defaultPort: UInt16 = 9710
    static let defaultOpenAIUpstream = "https://api.openai.com"
    static let defaultAnthropicUpstream = "https://api.anthropic.com"

    private var server: LLMProxyServer
    let statsStore: LLMStatsStore
    let usageObserver: LLMUsageObserver
    /// Keychain-backed credential store for non-Anthropic upstreams.
    /// Lives at the coordinator (not on each rebuilt server) so the
    /// underlying Keychain handle survives `rebuildServer()` and
    /// stays consistent across upstream URL changes.
    let credentialsStore: RouterCredentialsStore
    /// Routing-table resolver, paired with `credentialsStore`. Single
    /// owner per coordinator so active-profile state and custom-
    /// profile mutations don't get reset on `rebuildServer()`.
    let profileStore: UpstreamProfileStore
    private(set) var isRunning = false

    var port: UInt16 { server.configuration.port }
    var openAIUpstream: URL { server.configuration.openAIUpstream }
    var anthropicUpstream: URL { server.configuration.anthropicUpstream }

    init() {
        let credentials = RouterCredentialsStore.live()
        let profiles = UpstreamProfileStore()
        self.credentialsStore = credentials
        self.profileStore = profiles
        self.server = LLMProxyServer(
            configuration: Self.makeConfiguration(),
            credentialsStore: credentials,
            profileResolver: profiles
        )
        let store = LLMStatsStore()
        self.statsStore = store
        self.usageObserver = LLMUsageObserver(store: store)
    }

    static func makeConfiguration() -> LLMProxyConfiguration {
        let rawPort = UserDefaults.standard.integer(forKey: portDefaultsKey)
        let port: UInt16 = (rawPort > 0 && rawPort <= 65535) ? UInt16(rawPort) : defaultPort
        let openAI = readUpstream(
            key: openAIUpstreamDefaultsKey,
            fallback: defaultOpenAIUpstream
        )
        let anthropic = readUpstream(
            key: anthropicUpstreamDefaultsKey,
            fallback: defaultAnthropicUpstream
        )
        return LLMProxyConfiguration(
            port: port,
            anthropicUpstream: anthropic,
            openAIUpstream: openAI
        )
    }

    private static func readUpstream(key: String, fallback: String) -> URL {
        if let stored = UserDefaults.standard.string(forKey: key),
           let url = validatedUpstream(stored) {
            return url
        }
        return URL(string: fallback)!
    }

    /// Accepts only http/https URLs with a host. Anything else falls
    /// back to the default — protects against pasting paths with
    /// scheme typos that would otherwise fail at request time.
    static func validatedUpstream(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    func start() {
        guard !isRunning else { return }
        server.setObserver(usageObserver)
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

    /// Persist the new port and rebuild the underlying NWListener.
    /// Stops + restarts only if it was running; if the user manually
    /// stopped the proxy and edits the port, the next manual start
    /// picks up the new value.
    func setPort(_ newPort: UInt16) {
        UserDefaults.standard.set(Int(newPort), forKey: Self.portDefaultsKey)
        rebuildServer()
    }

    /// Persist a new OpenAI-compatible upstream and rebuild. Use
    /// `LLMProxyCoordinator.validatedUpstream(_:)` to vet input first.
    func setOpenAIUpstream(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.openAIUpstreamDefaultsKey)
        rebuildServer()
    }

    func setAnthropicUpstream(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.anthropicUpstreamDefaultsKey)
        rebuildServer()
    }

    private func rebuildServer() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.server = LLMProxyServer(
            configuration: Self.makeConfiguration(),
            credentialsStore: credentialsStore,
            profileResolver: profileStore
        )
        if wasRunning { start() }
    }
}
