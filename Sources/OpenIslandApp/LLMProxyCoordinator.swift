import Foundation
import OpenIslandCore
import os

/// Owns the lifecycle of `LLMProxyServer` from the app side, plus the
/// stats store + usage observer that live alongside it.
///
/// **Three-port routing.** Each `ProviderGroup` gets its own
/// listener (9710/9711/9712) and its own `LLMUpstreamHealthMonitor`,
/// but all three share a single `RouterCredentialsStore`,
/// `UpstreamProfileStore`, `LLMStatsStore`, and `LLMUsageObserver`.
/// The shared stores keep credential / active-profile state
/// coherent across listeners; the per-group monitors keep upstream
/// degradation in one provider from polluting another's health
/// banner.
@MainActor
final class LLMProxyCoordinator {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMProxyCoordinator")
    static let portDefaultsKey = "OpenIsland.LLMProxy.port"
    static let openAIUpstreamDefaultsKey = "OpenIsland.LLMProxy.openAIUpstream"
    static let anthropicUpstreamDefaultsKey = "OpenIsland.LLMProxy.anthropicUpstream"
    static let defaultPort: UInt16 = 9710
    static let defaultOpenAIUpstream = "https://api.openai.com"
    static let defaultAnthropicUpstream = "https://api.anthropic.com"

    /// One server-and-monitor pair per provider group. Built fresh
    /// in `init` and on every `rebuildServers()` (port/upstream
    /// edit). Iteration order is stable via `ProviderGroup.allCases`
    /// — log lines and lifecycle order match the official-Claude →
    /// deepseek → thirdParty visual order in the routing pane.
    private struct GroupListener {
        let server: LLMProxyServer
        let healthMonitor: LLMUpstreamHealthMonitor
    }
    private var listenersByGroup: [ProviderGroup: GroupListener]
    /// Defensive fallback returned by `healthMonitor` if a caller
    /// reads it before `init` has populated `listenersByGroup`.
    /// Should never be observed in practice since init is sync.
    private let fallbackHealthMonitor = LLMUpstreamHealthMonitor()

    let statsStore: LLMStatsStore
    let usageObserver: LLMUsageObserver
    /// Keychain-backed credential store, shared across all three
    /// listeners. Lives at the coordinator (not per-server) so a
    /// `rebuildServers()` doesn't churn the Keychain handle.
    let credentialsStore: RouterCredentialsStore
    /// Routing-table resolver, also shared. The store's lock makes
    /// it safe for three servers to read concurrently; mutations
    /// (profile add / active flip) come from the main actor.
    let profileStore: UpstreamProfileStore
    private(set) var isRunning = false

    /// Loopback port for the official-Claude listener. The legacy
    /// `port` exposure historically meant "the proxy port" —
    /// preserved here so existing UI / shims that hardcode 9710
    /// still see a well-defined value. New code that needs to know
    /// a non-Claude port should use `port(for:)`.
    var port: UInt16 { port(for: .officialClaude) }
    var openAIUpstream: URL {
        listenersByGroup[.officialClaude]?.server.configuration.openAIUpstream
            ?? URL(string: Self.defaultOpenAIUpstream)!
    }
    var anthropicUpstream: URL {
        listenersByGroup[.officialClaude]?.server.configuration.anthropicUpstream
            ?? URL(string: Self.defaultAnthropicUpstream)!
    }

    /// Loopback port for a specific provider group. Falls back to
    /// the group's static `defaultLoopbackPort` if the listener
    /// hasn't been built (e.g. test fixture without `init` having
    /// run yet — defensive only).
    func port(for group: ProviderGroup) -> UInt16 {
        listenersByGroup[group]?.server.configuration.port
            ?? group.defaultLoopbackPort
    }

    /// Sliding-window health metric for the **currently active**
    /// profile's group. `ModelRoutingPane` reads this to surface
    /// "your upstream looks degraded" — the banner reflects the
    /// group the user is actively talking to, not a global blend.
    /// `setActiveUpstreamProfile` resets the monitor for the new
    /// active group so the previous upstream's history doesn't
    /// follow.
    var healthMonitor: LLMUpstreamHealthMonitor {
        let activeProfile = profileStore.currentActiveProfile()
        let activeGroup = ProviderGroup.infer(profile: activeProfile)
        return listenersByGroup[activeGroup]?.healthMonitor ?? fallbackHealthMonitor
    }

    init() {
        let credentials = RouterCredentialsStore.live()
        let profiles = UpstreamProfileStore()
        self.credentialsStore = credentials
        self.profileStore = profiles
        // Run the legacy-upstream migration BEFORE building any
        // listener, so a profile that was implicit in the old
        // single-listener `openAIUpstream` / `anthropicUpstream`
        // UserDefault becomes a real custom profile in the store
        // and shows up in routing UI / per-group attribution from
        // launch one. Idempotent: subsequent runs see the
        // migration-marker key and no-op.
        Self.migrateLegacyUpstreamsIfNeeded(into: profiles)
        self.listenersByGroup = Self.buildListeners(
            credentials: credentials,
            profiles: profiles
        )
        let store = LLMStatsStore()
        self.statsStore = store
        self.usageObserver = LLMUsageObserver(store: store)
        // Feed the profile resolver to the observer so the pricing
        // fallback path can read ProfileCostMetadata for models not
        // in the static LLMPricing table (e.g. deepseek-v4-pro).
        self.usageObserver.profileResolver = profiles
    }

    // MARK: - Legacy upstream migration (Billing P2)

    /// Marker so we only attempt the migration once per install. The
    /// migration is idempotent in result but we don't want to spam
    /// the logger every launch with "no legacy upstream to migrate".
    static let legacyMigrationDoneKey = "OpenIsland.LLMProxy.legacyMigration.v1"
    static let legacyOpenAIProfileID = "legacy-openai-upstream"
    static let legacyAnthropicProfileID = "legacy-anthropic-upstream"

    /// Promote the pre-three-port `openAIUpstream` /
    /// `anthropicUpstream` UserDefaults into first-class custom
    /// profiles. Codex's review pointed out that ripping the
    /// "Upstream URL" inputs out of the spend pane without
    /// migrating them silently strands the user's configuration —
    /// this commit's job is to land the data; later UI commits hide
    /// the inputs.
    ///
    /// Migration rules:
    /// - Read legacy key. If unset OR equal to the well-known
    ///   default (`https://api.openai.com` /
    ///   `https://api.anthropic.com`), skip — there's nothing to
    ///   migrate.
    /// - Otherwise create a custom profile with a stable id
    ///   (`legacy-openai-upstream` / `legacy-anthropic-upstream`)
    ///   pointing at the user's URL. `addCustomProfile` is
    ///   idempotent on (id, profile) so a double-launch race or a
    ///   stale marker isn't dangerous.
    /// - Custom profile lands in `thirdParty` group via
    ///   `ProviderGroup.infer(profile:)` regardless of host —
    ///   billing / blame for the user's reverse proxy is theirs,
    ///   not the upstream vendor's.
    /// - Legacy UserDefault keys are kept on disk so any code path
    ///   that still reads them gets the same value. The next
    ///   commit hides the inputs; a later major version can drop
    ///   the keys after telemetry shows zero non-default writes.
    static func migrateLegacyUpstreamsIfNeeded(
        into profiles: UpstreamProfileStore,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: legacyMigrationDoneKey) else { return }
        defer {
            defaults.set(true, forKey: legacyMigrationDoneKey)
        }
        migrateOne(
            key: openAIUpstreamDefaultsKey,
            defaultValue: defaultOpenAIUpstream,
            profileID: legacyOpenAIProfileID,
            displayName: "Legacy OpenAI Upstream",
            into: profiles,
            defaults: defaults
        )
        migrateOne(
            key: anthropicUpstreamDefaultsKey,
            defaultValue: defaultAnthropicUpstream,
            profileID: legacyAnthropicProfileID,
            displayName: "Legacy Anthropic Upstream",
            into: profiles,
            defaults: defaults
        )
    }

    private static func migrateOne(
        key: String,
        defaultValue: String,
        profileID: String,
        displayName: String,
        into profiles: UpstreamProfileStore,
        defaults: UserDefaults
    ) {
        guard let stored = defaults.string(forKey: key),
              !stored.isEmpty,
              stored != defaultValue,
              let url = validatedUpstream(stored) else {
            return
        }
        let profile = UpstreamProfile(
            id: profileID,
            displayName: displayName,
            baseURL: url,
            keychainAccount: profileID,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        do {
            try profiles.addCustomProfile(profile)
            logger.info(
                "Legacy upstream \(key, privacy: .public) → migrated to custom profile \(profileID, privacy: .public) (\(url.absoluteString, privacy: .public))"
            )
        } catch {
            // Common case: a previous failed run already wrote the
            // profile. addCustomProfile rejects exact-id collisions
            // with the same id, but tolerates re-add of the same
            // profile content — log and move on.
            logger.notice(
                "Legacy upstream \(key, privacy: .public) migration skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Build one server-and-monitor pair per `ProviderGroup`. The
    /// official-Claude listener honors the legacy
    /// `OpenIsland.LLMProxy.port` UserDefault (so users who
    /// remapped 9710 keep their override); deepseek + thirdParty
    /// always bind their group default. Future: per-group port
    /// override UserDefaults.
    private static func buildListeners(
        credentials: RouterCredentialsStore,
        profiles: UpstreamProfileStore
    ) -> [ProviderGroup: GroupListener] {
        var result: [ProviderGroup: GroupListener] = [:]
        let openAI = readUpstream(
            key: openAIUpstreamDefaultsKey,
            fallback: defaultOpenAIUpstream
        )
        let anthropic = readUpstream(
            key: anthropicUpstreamDefaultsKey,
            fallback: defaultAnthropicUpstream
        )
        for group in ProviderGroup.allCases {
            let port: UInt16 = {
                if group == .officialClaude {
                    let raw = UserDefaults.standard.integer(forKey: portDefaultsKey)
                    if raw > 0 && raw <= 65535 { return UInt16(raw) }
                }
                return group.defaultLoopbackPort
            }()
            let monitor = LLMUpstreamHealthMonitor()
            let config = LLMProxyConfiguration(
                port: port,
                anthropicUpstream: anthropic,
                openAIUpstream: openAI,
                providerGroup: group
            )
            let server = LLMProxyServer(
                configuration: config,
                credentialsStore: credentials,
                profileResolver: profiles,
                healthMonitor: monitor
            )
            result[group] = GroupListener(server: server, healthMonitor: monitor)
        }
        return result
    }

    /// Legacy single-config builder kept for tests and the
    /// `rebuildServers` path. The three-port equivalent is
    /// `buildListeners(credentials:profiles:)`.
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

    /// Accepts only https URLs with a public host. Private / loopback
    /// / link-local hosts are rejected to prevent SSRF via custom
    /// upstream URLs pointing at internal services.
    static func validatedUpstream(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host, !host.isEmpty,
              !Self.isPrivateOrLoopback(host: host)
        else { return nil }
        return url
    }

    /// Internal-visible helper exposed for retroactive scanning of
    /// already-persisted custom profiles (C-1 backfill). Same logic
    /// `validatedUpstream` runs on new entries; lifted to a static
    /// so `UpstreamProfileStore.scanCustomProfiles` can use it
    /// without taking a dependency on the App layer.
    /// `nonisolated` so it can be passed as a `@Sendable` closure
    /// from non-MainActor call sites (the store's scanner).
    nonisolated static func isPublicHost(_ host: String) -> Bool {
        !isPrivateOrLoopback(host: host)
    }

    nonisolated private static func isPrivateOrLoopback(host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" {
            return true
        }
        // Quick check for common metadata hostnames
        if lower.hasSuffix(".internal") || lower.hasSuffix(".local") {
            return true
        }
        // Check IPv4 private / link-local ranges via simple prefix match
        let octets = lower.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            if octets[0] == 100, (64...127).contains(octets[1]) { return true }
            if octets[0] == 0 { return true }
        }
        return false
    }

    /// C-1 backfill: scan persisted custom profiles against today's
    /// SSRF policy and downgrade `active` if it points at a now-
    /// disallowed host. Profiles that fail are NOT deleted — left
    /// in the store so the user can edit / review them via the
    /// routing pane. Idempotent; safe to call on every app launch.
    /// Logs at warning level for any scrub action.
    @discardableResult
    func backfillSSRFPolicy() -> UpstreamProfileStore.CustomProfileScan {
        let scan = profileStore.scanCustomProfiles(isHostAllowed: Self.isPublicHost)
        if !scan.disallowed.isEmpty {
            Self.logger.warning(
                "SSRF backfill: \(scan.disallowed.count, privacy: .public) custom profile(s) have non-public hosts and cannot be activated: \(scan.disallowed.joined(separator: ", "), privacy: .public)"
            )
            let downgraded = profileStore.resetActiveIfInDisallowedList(Set(scan.disallowed))
            if let prev = downgraded {
                Self.logger.error(
                    "SSRF backfill: active profile \"\(prev, privacy: .public)\" pointed at a private/loopback host — reset to default (\(UpstreamProfileStore.defaultActiveProfileId, privacy: .public))."
                )
            }
        }
        return scan
    }

    func start() {
        guard !isRunning else { return }
        // C-1 backfill: vet persisted custom profiles BEFORE any
        // listener accepts traffic. If the active profile points
        // at a private/loopback host, downgrade to default here so
        // the very first request after start uses a safe upstream.
        backfillSSRFPolicy()
        // All three listeners share the same observer — usage data
        // accumulates in a single LLMStatsStore, with each record
        // tagged by the upstream profile so the UI can split it by
        // group later.
        for group in ProviderGroup.allCases {
            guard let listener = listenersByGroup[group] else { continue }
            listener.server.setObserver(usageObserver)
            do {
                try listener.server.start()
                Self.logger.info(
                    "LLM proxy [\(group.logTag, privacy: .public)] started on port \(listener.server.configuration.port)"
                )
            } catch {
                Self.logger.error(
                    "LLM proxy [\(group.logTag, privacy: .public)] failed to start: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        for group in ProviderGroup.allCases {
            guard let listener = listenersByGroup[group] else { continue }
            listener.server.stop()
        }
        isRunning = false
    }

    /// Persist the new port for the official-Claude listener and
    /// rebuild. Other groups continue using their static defaults
    /// — per-group port override UI is a follow-up commit.
    func setPort(_ newPort: UInt16) {
        UserDefaults.standard.set(Int(newPort), forKey: Self.portDefaultsKey)
        rebuildServers()
    }

    /// Persist a new OpenAI-compatible upstream and rebuild. Use
    /// `LLMProxyCoordinator.validatedUpstream(_:)` to vet input first.
    func setOpenAIUpstream(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.openAIUpstreamDefaultsKey)
        rebuildServers()
    }

    func setAnthropicUpstream(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.anthropicUpstreamDefaultsKey)
        rebuildServers()
    }

    private func rebuildServers() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.listenersByGroup = Self.buildListeners(
            credentials: credentialsStore,
            profiles: profileStore
        )
        if wasRunning { start() }
    }
}
