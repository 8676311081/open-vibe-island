import Foundation

/// Provenance for a resolved profile: did it come from the user's GUI
/// selection (the active card), or from a per-request override
/// (e.g. URL sentinel set by the `claude-3` shim via `OI_PROFILE`)?
/// Carried in `LLMProxyRequestContext.profileSelectionSource` so the
/// observer / spend layer can attribute usage correctly.
public enum ProfileSelectionSource: String, Sendable, Codable {
    case activeDefault
    case perRequestOverride
}

/// Result of `UpstreamProfileResolver.resolveProfile(overrideId:)`.
/// The proxy resolves once at request entry and threads this through
/// the forward path. Downstream code (rewriter / pricing / observer)
/// reads from this struct rather than re-reading active state, so a
/// mid-flight active-profile switch doesn't tear an in-progress
/// request between resolution and forwarding.
public struct ResolvedProfile: Sendable, Equatable {
    public let profile: UpstreamProfile
    public let source: ProfileSelectionSource
    public init(profile: UpstreamProfile, source: ProfileSelectionSource) {
        self.profile = profile
        self.source = source
    }
}

/// Errors the resolver may raise. Today only `unknownOverride` —
/// surfaced as a 400 by the proxy in T3 when the URL sentinel
/// references an id not in the registry. Stored here (not at the call
/// site) so the proxy code stays clean and the error type is
/// importable from tests.
public enum UpstreamProfileResolverError: Error, Equatable {
    case unknownOverride(id: String)
}

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
    /// Look up a profile by its stable id. The default implementation
    /// only knows about the active profile (sufficient for the test
    /// fakes that do not maintain a registry); concrete stores like
    /// `UpstreamProfileStore` override this to walk `allProfiles`.
    func profile(id: String) -> UpstreamProfile?
    /// Single resolution call invoked at request entry. `overrideId`
    /// is the per-request override (typically parsed out of a URL
    /// sentinel by the proxy in T3); when `nil`, returns the active
    /// profile as `.activeDefault`. When `overrideId` is provided but
    /// not registered, throws `.unknownOverride(id:)` so the proxy
    /// can return a 400 instead of silently falling back to active.
    func resolveProfile(overrideId: String?) throws -> ResolvedProfile
    /// Stable, sorted list of all profile ids known to this resolver.
    /// Used in T4's 400 body for the `available` field so users
    /// hitting a typo get a concrete list of valid alternatives. The
    /// default implementation returns just the active profile id —
    /// adequate for test fakes; concrete stores override.
    func availableProfileIds() -> [String]
}

/// Default protocol implementations. Test fakes that adopt
/// `UpstreamProfileResolver` get these for free and only have to
/// implement the two original methods. Concrete stores override
/// `profile(id:)` for registry-wide lookup.
public extension UpstreamProfileResolver {
    func profile(id: String) -> UpstreamProfile? {
        let active = currentActiveProfile()
        return active.id == id ? active : nil
    }

    func resolveProfile(overrideId: String?) throws -> ResolvedProfile {
        if let overrideId, !overrideId.isEmpty {
            guard let p = profile(id: overrideId) else {
                throw UpstreamProfileResolverError.unknownOverride(id: overrideId)
            }
            return ResolvedProfile(profile: p, source: .perRequestOverride)
        }
        return ResolvedProfile(
            profile: currentActiveProfile(),
            source: .activeDefault
        )
    }

    func availableProfileIds() -> [String] {
        // Test-fake fallback. Concrete stores override with the full
        // builtins-plus-custom registry.
        [currentActiveProfile().id]
    }
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

    /// Concrete override: walk the full registry (builtins + custom).
    /// Falls back to the protocol default's "active-only" behavior
    /// implicitly via the existing `allProfiles.first` shape, but here
    /// we scan all known profiles, which is what callers like the
    /// proxy / observer need when resolving an override id that does
    /// not happen to be the active one.
    public func profile(id: String) -> UpstreamProfile? {
        allProfiles.first { $0.id == id }
    }

    /// Concrete override: returns the full sorted list of registered
    /// profile ids. Used by T4 to build the `available` field in the
    /// 400 response when an override id is unknown. Sort is alpha so
    /// the JSON output is stable across builds (helps test fixtures
    /// and human grep).
    public func availableProfileIds() -> [String] {
        allProfiles.map(\.id).sorted()
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
        let sorted = candidates.sorted { $0.baseURL.path.count > $1.baseURL.path.count }
        guard let first = sorted.first else { return nil }
        let active = currentActiveProfile()
        // When several profiles share the exact same base URL
        // (common for custom Pro/Flash profiles on the same gateway),
        // prefer the active profile for credential lookup. Keep this
        // constrained to the best path-prefix group; otherwise an
        // active empty-path profile such as Anthropic Native would
        // incorrectly beat a more specific profile path.
        let bestPath = first.baseURL.path
        if active.baseURL.host?.lowercased() == host,
           active.baseURL.path == bestPath,
           sorted.contains(where: { $0.id == active.id }) {
            return active
        }
        return first
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
