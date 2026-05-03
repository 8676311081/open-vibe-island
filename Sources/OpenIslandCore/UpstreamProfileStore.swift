import Foundation

/// Read-only side of the routing table — used by the proxy hot path
/// (`LLMRequestRewriter`) to resolve an upstream URL to its profile.
/// Kept narrow on purpose: the rewriter doesn't need to know about
/// custom-profile mutation, only "given this URL, which profile
/// matches".
public protocol UpstreamProfileResolver: Sendable {
    /// Returns the longest-prefix-matching profile, or `nil` if no
    /// profile's `baseURL.host` and path prefix the request URL.
    func profileMatching(url: URL) -> UpstreamProfile?
    /// Currently-active profile (the one the user selected in the
    /// routing pane). Used by future commits' compact-pill chip and
    /// model-card "active" badge.
    func currentActiveProfile() -> UpstreamProfile
}

/// Single owner of the active-profile + custom-profiles state.
/// Backed by `UserDefaults` with namespaced keys
/// (`OpenIsland.LLMProxy.activeProfileId`,
/// `OpenIsland.LLMProxy.customProfiles`).
///
/// **Why `final class + NSLock` instead of `actor`:**
///
/// This store is read on the proxy hot path — every Anthropic API
/// request passes through `profileMatching(url:)` to determine
/// whether the Authorization rewrite applies. Making it an actor
/// would force `await` at the call site, propagating `async`
/// through `LLMRequestRewriter`, the request handling chain, and
/// ultimately the `NWListener` handler — turning sync callbacks
/// into async ones with suspension points on every request.
///
/// Profile data is small (< 50 entries even with custom additions),
/// mutations are rare (only on user-initiated profile add / remove
/// / switch). NSLock contention is negligible. Sync read path
/// keeps the proxy fast.
///
/// If a future Swift evolution adds a sync-callable actor variant
/// (sometimes discussed as "isolated subclass" or "actor accessors"
/// — none accepted at time of writing), revisit. Until then:
/// final class + NSLock is the right tool. Same pattern as
/// `RouterCredentialsStore`.
public final class UpstreamProfileStore: UpstreamProfileResolver, @unchecked Sendable {
    public static let activeProfileIdDefaultsKey = "OpenIsland.LLMProxy.activeProfileId"
    public static let customProfilesDefaultsKey = "OpenIsland.LLMProxy.customProfiles"
    public static let defaultActiveProfileId = "anthropic-native"

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Read

    /// All profiles known to the store: builtins first, then custom
    /// in insertion order. Builtins live in `BuiltinProfiles.all`;
    /// custom come from JSON-decoded `UserDefaults`.
    public var allProfiles: [UpstreamProfile] {
        BuiltinProfiles.all + readCustomProfiles()
    }

    public func currentActiveProfile() -> UpstreamProfile {
        let activeId = userDefaults.string(forKey: Self.activeProfileIdDefaultsKey)
            ?? Self.defaultActiveProfileId
        return allProfiles.first { $0.id == activeId } ?? BuiltinProfiles.anthropicNative
    }

    public func profileMatching(url: URL) -> UpstreamProfile? {
        guard let host = url.host?.lowercased() else { return nil }
        let reqPath = url.path
        // Filter to host-matching profiles, then keep ones whose
        // baseURL path is a prefix of the request path. Sort by
        // path length descending so longest-match wins — guards
        // against two custom profiles sharing a host but with
        // different sub-paths (e.g. /openai vs /openai/proxy).
        let candidates = allProfiles.filter { profile in
            guard profile.baseURL.host?.lowercased() == host else { return false }
            let profPath = profile.baseURL.path
            if profPath.isEmpty {
                // Empty profile path matches any path on the host
                // (Anthropic native: baseURL = https://api.anthropic.com).
                return true
            }
            if reqPath == profPath { return true }
            return reqPath.hasPrefix(profPath + "/")
        }
        return candidates.sorted { $0.baseURL.path.count > $1.baseURL.path.count }.first
    }

    // MARK: - Active profile (write)

    /// Switch the active profile. Throws if `id` doesn't correspond
    /// to any built-in or custom profile (defensive: avoids leaving
    /// the store in a state where the active id dangles).
    public func setActiveProfile(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard allProfiles.contains(where: { $0.id == id }) else {
            throw UpstreamProfileError.unknownProfile(id: id)
        }
        userDefaults.set(id, forKey: Self.activeProfileIdDefaultsKey)
    }

    // MARK: - Custom profiles (write)

    /// Add a custom profile. Profile must have `isCustom = true`.
    /// Re-adding a profile with the same id replaces the existing
    /// one (same UX as updating a row).
    public func addCustomProfile(_ profile: UpstreamProfile) throws {
        lock.lock(); defer { lock.unlock() }
        guard profile.isCustom else {
            throw UpstreamProfileError.cannotAddBuiltinAsCustom
        }
        guard !BuiltinProfiles.all.contains(where: { $0.id == profile.id }) else {
            throw UpstreamProfileError.idCollidesWithBuiltin(id: profile.id)
        }
        var custom = readCustomProfiles()
        if let idx = custom.firstIndex(where: { $0.id == profile.id }) {
            custom[idx] = profile
        } else {
            custom.append(profile)
        }
        try writeCustomProfiles(custom)
    }

    /// Remove a custom profile. Built-ins cannot be removed (throws
    /// `cannotRemoveBuiltin`). If the removed profile was the active
    /// one, active falls back to `defaultActiveProfileId`.
    public func removeCustomProfile(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if BuiltinProfiles.all.contains(where: { $0.id == id }) {
            throw UpstreamProfileError.cannotRemoveBuiltin(id: id)
        }
        var custom = readCustomProfiles()
        custom.removeAll { $0.id == id }
        try writeCustomProfiles(custom)
        // If the active profile was removed, fall back to default
        // so future requests don't hit "no profile matches" silently.
        let activeId = userDefaults.string(forKey: Self.activeProfileIdDefaultsKey)
        if activeId == id {
            userDefaults.set(Self.defaultActiveProfileId, forKey: Self.activeProfileIdDefaultsKey)
        }
    }

    // MARK: - Persistence

    private func readCustomProfiles() -> [UpstreamProfile] {
        guard let data = userDefaults.data(forKey: Self.customProfilesDefaultsKey) else {
            return []
        }
        // Corrupt JSON => empty list rather than crash. Worst case
        // user re-enters their custom profiles; better than the app
        // refusing to start.
        return (try? JSONDecoder().decode([UpstreamProfile].self, from: data)) ?? []
    }

    private func writeCustomProfiles(_ profiles: [UpstreamProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        userDefaults.set(data, forKey: Self.customProfilesDefaultsKey)
    }
}
