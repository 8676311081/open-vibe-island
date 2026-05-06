import Testing
import Foundation
@testable import OpenIslandCore
@testable import OpenIslandApp

/// Verifies the Billing P2 migration: pre-three-port
/// `openAIUpstream` / `anthropicUpstream` UserDefaults get promoted
/// into first-class custom profiles on app launch, so the spend
/// pane can later hide those inputs without stranding configuration.
@Suite struct LegacyUpstreamMigrationTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "test.legacy-upstream-migration.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeIsolatedProfileStore(defaults: UserDefaults) -> UpstreamProfileStore {
        UpstreamProfileStore(userDefaults: defaults)
    }

    @MainActor
    @Test
    func nonDefaultOpenAIUpstreamMigratesToCustomProfile() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            "https://api2.tabcode.cc/openai/plus",
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        let migrated = profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID)
        #expect(migrated != nil)
        #expect(migrated?.baseURL.absoluteString == "https://api2.tabcode.cc/openai/plus")
        #expect(migrated?.isCustom == true)
        // Marker flips so a second migration call is a no-op.
        #expect(defaults.bool(forKey: LLMProxyCoordinator.legacyMigrationDoneKey) == true)
    }

    @MainActor
    @Test
    func defaultOpenAIUpstreamSkipsMigration() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            LLMProxyCoordinator.defaultOpenAIUpstream,  // exact default value
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        // Nothing migrated — user wasn't using a custom upstream.
        #expect(profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID) == nil)
        // But marker still flips so we don't re-check on every launch.
        #expect(defaults.bool(forKey: LLMProxyCoordinator.legacyMigrationDoneKey) == true)
    }

    @MainActor
    @Test
    func unsetUpstreamSkipsMigration() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        // No upstream configured at all (fresh install).

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        #expect(profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID) == nil)
        #expect(profiles.profile(id: LLMProxyCoordinator.legacyAnthropicProfileID) == nil)
    }

    @MainActor
    @Test
    func bothUpstreamsMigrateIndependently() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            "https://api2.tabcode.cc/openai/plus",
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )
        defaults.set(
            "https://my-anthropic-proxy.example.com",
            forKey: LLMProxyCoordinator.anthropicUpstreamDefaultsKey
        )

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        let openAI = profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID)
        let anthropic = profiles.profile(id: LLMProxyCoordinator.legacyAnthropicProfileID)
        #expect(openAI != nil)
        #expect(anthropic != nil)
        #expect(openAI?.baseURL.absoluteString == "https://api2.tabcode.cc/openai/plus")
        #expect(anthropic?.baseURL.absoluteString == "https://my-anthropic-proxy.example.com")
    }

    @MainActor
    @Test
    func legacyMigrationIsIdempotentAcrossSecondLaunch() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            "https://api2.tabcode.cc/openai/plus",
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )

        // First run migrates.
        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )
        let countAfterFirst = profiles.allProfiles.filter(\.isCustom).count

        // Second run sees the marker, no-ops.
        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )
        let countAfterSecond = profiles.allProfiles.filter(\.isCustom).count

        #expect(countAfterFirst == countAfterSecond)
        #expect(countAfterFirst >= 1)  // at least the openAI legacy profile
    }

    @MainActor
    @Test
    func privateUpstreamRejectedBySSRFGuardSkipsMigration() {
        // The validatedUpstream helper rejects private/loopback URLs
        // (C-1's SSRF check). A user who somehow got a 192.168.* URL
        // into UserDefaults shouldn't have it round-trip into a real
        // profile — rejection here matches the rejection that happens
        // for any new profile attempt.
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            "http://192.168.1.100:8080",
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        #expect(profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID) == nil)
    }

    @MainActor
    @Test
    func migratedCustomProfileLandsInThirdPartyGroup() {
        let defaults = makeIsolatedDefaults()
        let profiles = makeIsolatedProfileStore(defaults: defaults)
        defaults.set(
            "https://api2.tabcode.cc/openai/plus",
            forKey: LLMProxyCoordinator.openAIUpstreamDefaultsKey
        )

        LLMProxyCoordinator.migrateLegacyUpstreamsIfNeeded(
            into: profiles,
            defaults: defaults
        )

        // Per ProviderGroup.infer, every isCustom profile lands in
        // thirdParty regardless of host — even Anthropic-host
        // legacy profiles. Migration must respect that.
        guard let migrated = profiles.profile(id: LLMProxyCoordinator.legacyOpenAIProfileID) else {
            Issue.record("Legacy OpenAI profile didn't migrate")
            return
        }
        #expect(ProviderGroup.infer(profile: migrated) == .thirdParty)
    }
}
