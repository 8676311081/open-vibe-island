import Foundation
import Testing
@testable import OpenIslandCore

/// Each test gets an isolated `UserDefaults` suite so `set...` /
/// `removeObject` calls don't pollute the real app domain or other
/// tests' state. Suite names are UUID-prefixed; `removePersistentDomain`
/// in `defer` cleans up the on-disk plist.
private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suite = "OpenIslandTests.UpstreamProfile.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, suite)
}

private func makeCustomProfile(
    id: String = "test-custom",
    host: String = "example.com",
    keychainAccount: String? = "test-account"
) -> UpstreamProfile {
    UpstreamProfile(
        id: id,
        displayName: "modelRouting.profile.custom.\(id)",
        baseURL: URL(string: "https://\(host)/api")!,
        keychainAccount: keychainAccount,
        modelOverride: nil,
        isCustom: true,
        costMetadata: nil
    )
}

struct UpstreamProfileStoreTests {
    // MARK: - Builtins

    @Test
    func builtinsCompleteAndStable() {
        // Three built-ins ship in this order (anthropic-native at
        // index 0 is load-bearing for the default-active fallback).
        let ids = BuiltinProfiles.all.map(\.id)
        #expect(ids == ["anthropic-native", "deepseek-v4-pro", "deepseek-v4-flash"])

        // Anthropic native passes through (no keychain account).
        #expect(BuiltinProfiles.anthropicNative.keychainAccount == nil)
        // Both DeepSeek variants share the same Keychain account name
        // (one DeepSeek API key serves both Pro and Flash) and the
        // same baseURL (the variant is selected by body model field,
        // future commit).
        #expect(BuiltinProfiles.deepseekV4Pro.keychainAccount == "deepseek")
        #expect(BuiltinProfiles.deepseekV4Flash.keychainAccount == "deepseek")
        #expect(BuiltinProfiles.deepseekV4Pro.baseURL == BuiltinProfiles.deepseekV4Flash.baseURL)
        // Discount window populated for the DeepSeek ones (UI
        // depends on this for the expiring-discount chip).
        #expect(BuiltinProfiles.deepseekV4Pro.costMetadata?.discountExpiresAt != nil)
        #expect(BuiltinProfiles.deepseekV4Flash.costMetadata?.discountExpiresAt != nil)
        // Anthropic native is at full price, no expiring discount.
        #expect(BuiltinProfiles.anthropicNative.costMetadata?.discountExpiresAt == nil)
    }

    // MARK: - Active profile

    @Test
    func activeProfileDefaultsToAnthropicNative() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        // Fresh defaults — no key set. Must fall back to Anthropic
        // native, never silently route to a DeepSeek profile.
        #expect(store.currentActiveProfile().id == "anthropic-native")
    }

    @Test
    func setActiveProfilePersistsAcrossNewStoreInstances() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store1 = UpstreamProfileStore(userDefaults: defaults)
        try store1.setActiveProfile("deepseek-v4-pro")
        // New store instance reads the same UserDefaults — proves
        // setActiveProfile actually wrote, not just cached in memory.
        let store2 = UpstreamProfileStore(userDefaults: defaults)
        #expect(store2.currentActiveProfile().id == "deepseek-v4-pro")
    }

    @Test
    func setActiveProfileToUnknownIdThrows() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        #expect(throws: UpstreamProfileError.self) {
            try store.setActiveProfile("nonexistent-id")
        }
        // And the active profile must not have changed.
        #expect(store.currentActiveProfile().id == "anthropic-native")
    }

    // MARK: - Custom profiles

    @Test
    func customProfileAddPersistsAndAppearsInAllProfiles() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let custom = makeCustomProfile(id: "my-azure", host: "myorg.openai.azure.com")
        try store.addCustomProfile(custom)
        let all = store.allProfiles
        #expect(all.contains(where: { $0.id == "my-azure" }))
        // Builtins still present in the same canonical order.
        #expect(all.prefix(3).map(\.id) == ["anthropic-native", "deepseek-v4-pro", "deepseek-v4-flash"])
    }

    @Test
    func customProfileRemove() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let custom = makeCustomProfile(id: "to-remove")
        try store.addCustomProfile(custom)
        #expect(store.allProfiles.contains(where: { $0.id == "to-remove" }))
        try store.removeCustomProfile(id: "to-remove")
        #expect(!store.allProfiles.contains(where: { $0.id == "to-remove" }))
    }

    @Test
    func cannotRemoveBuiltinProfile() {
        // Per spec hard constraint #3: built-ins are immutable. The
        // store must reject removeCustomProfile against a builtin id
        // even though that id exists in `allProfiles`.
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        #expect(throws: UpstreamProfileError.cannotRemoveBuiltin(id: "anthropic-native")) {
            try store.removeCustomProfile(id: "anthropic-native")
        }
    }

    @Test
    func cannotAddBuiltinAsCustom() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        // Profile with a builtin id but isCustom=true would be a
        // sneaky way to override a builtin's behavior; refuse.
        let collidingId = UpstreamProfile(
            id: "anthropic-native",
            displayName: "spoof",
            baseURL: URL(string: "https://api.example.com")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(throws: UpstreamProfileError.idCollidesWithBuiltin(id: "anthropic-native")) {
            try store.addCustomProfile(collidingId)
        }
    }

    @Test
    func removingActiveCustomProfileFallsBackToDefault() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let custom = makeCustomProfile(id: "active-then-removed")
        try store.addCustomProfile(custom)
        try store.setActiveProfile("active-then-removed")
        #expect(store.currentActiveProfile().id == "active-then-removed")
        try store.removeCustomProfile(id: "active-then-removed")
        // Must not silently leave activeId dangling — fall back to
        // Anthropic native so the next request has a valid route.
        #expect(store.currentActiveProfile().id == "anthropic-native")
    }

    // MARK: - URL matching

    @Test
    func profileMatchingByURL() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        // Anthropic
        let anthropic = store.profileMatching(
            url: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        #expect(anthropic?.id == "anthropic-native")
        // DeepSeek (path under /anthropic)
        let deepseek = store.profileMatching(
            url: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
        )
        // V4 Pro and Flash share baseURL — first-match wins by
        // built-in array order, which is V4 Pro at index 1.
        #expect(deepseek?.id == "deepseek-v4-pro")
        // Unknown host
        let openai = store.profileMatching(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
        #expect(openai == nil)
    }

    @Test
    func profileMatchingDoesNotMisrouteOnPartialPathPrefix() throws {
        // Defensive: a request to "/anthropic-other/x" must not match
        // a profile whose baseURL path is "/anthropic". The matcher
        // requires the next character after the prefix to be `/`
        // (or the paths to be equal).
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let req = URL(string: "https://api.deepseek.com/anthropic-other/v1")!
        let matched = store.profileMatching(url: req)
        #expect(matched == nil, "/anthropic-other should not match /anthropic")
    }

    @Test
    func profileMatchingPrefersLongerPathPrefix() throws {
        // Two custom profiles on the same host, one with a deeper
        // path. Request matching the deeper path must resolve to the
        // deeper-path profile.
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let shallow = UpstreamProfile(
            id: "shallow",
            displayName: "x",
            baseURL: URL(string: "https://api.custom.com/v1")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        let deeper = UpstreamProfile(
            id: "deeper",
            displayName: "y",
            baseURL: URL(string: "https://api.custom.com/v1/special")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        try store.addCustomProfile(shallow)
        try store.addCustomProfile(deeper)
        let matched = store.profileMatching(
            url: URL(string: "https://api.custom.com/v1/special/messages")!
        )
        #expect(matched?.id == "deeper")
    }


    @Test
    func profileMatchingPrefersActiveWhenProfilesShareBaseURL() throws {
        // BuerAI-style setup: Pro and Flash profiles intentionally
        // share the same gateway URL but differ by modelOverride and
        // Keychain account. Auth lookup must follow the active
        // profile, not the first custom row on that host.
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpstreamProfileStore(userDefaults: defaults)
        let flash = UpstreamProfile(
            id: "buerai-flash",
            displayName: "BuerAI Flash",
            baseURL: URL(string: "https://api.buerai.top")!,
            keychainAccount: "custom-buerai-flash",
            modelOverride: "claude-sonnet-4-6",
            isCustom: true,
            costMetadata: nil
        )
        let pro = UpstreamProfile(
            id: "buerai-pro",
            displayName: "BuerAI Pro",
            baseURL: URL(string: "https://api.buerai.top")!,
            keychainAccount: "custom-buerai-pro",
            modelOverride: "claude-opus-4-6",
            isCustom: true,
            costMetadata: nil
        )
        try store.addCustomProfile(flash)
        try store.addCustomProfile(pro)
        try store.setActiveProfile("buerai-pro")

        let matched = store.profileMatching(
            url: URL(string: "https://api.buerai.top/v1/messages")!
        )
        #expect(matched?.id == "buerai-pro")
        #expect(matched?.keychainAccount == "custom-buerai-pro")
    }

    // MARK: - Codable round-trip

    @Test
    func upstreamProfileCodableRoundtripPreservesAllFields() throws {
        let original = UpstreamProfile(
            id: "x",
            displayName: "k",
            baseURL: URL(string: "https://example.com/p")!,
            keychainAccount: "acct",
            modelOverride: "m1",
            isCustom: true,
            costMetadata: ProfileCostMetadata(
                inputUSDPerMtok: 1.0,
                outputUSDPerMtok: 2.0,
                cacheReadUSDPerMtok: 0.1,
                contextWindowTokens: 100_000,
                discountExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                listInputUSDPerMtok: 4.0,
                listOutputUSDPerMtok: 8.0
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UpstreamProfile.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func legacyJSONWithoutListPriceFieldsDecodesWithZeroFallback() throws {
        // Pre-4.3 profiles serialized to UserDefaults won't have the
        // list* fields. The custom Codable init must accept that
        // shape and default both to 0 — otherwise an Open Island
        // upgrade breaks any user's existing custom profile.
        let legacyJSON = """
        {
          "id": "legacy",
          "displayName": "k",
          "baseURL": "https://example.com",
          "isCustom": true,
          "costMetadata": {
            "inputUSDPerMtok": 1.5,
            "outputUSDPerMtok": 3.0,
            "contextWindowTokens": 100000
          }
        }
        """
        let decoded = try JSONDecoder().decode(UpstreamProfile.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == "legacy")
        #expect(decoded.costMetadata?.listInputUSDPerMtok == 0)
        #expect(decoded.costMetadata?.listOutputUSDPerMtok == 0)
    }
}
