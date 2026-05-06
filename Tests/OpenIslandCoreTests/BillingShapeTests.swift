import Testing
import Foundation
@testable import OpenIslandCore

/// Coverage for `BillingShape.infer(profile:)`. The shape decides
/// what columns the spend UI renders for each profile; an incorrect
/// inference doesn't crash anything but produces a misleading UI
/// (USD column on a Claude Max profile, or no balance column on a
/// metered-credits provider).
@Suite struct BillingShapeTests {

    // MARK: - Builtins

    @Test
    func anthropicNativeBuiltinIsSubscriptionWindow() {
        #expect(BillingShape.infer(profile: BuiltinProfiles.anthropicNative)
                == .subscriptionWindow)
    }

    @Test
    func deepseekBuiltinsAreMeteredCredits() {
        #expect(BillingShape.infer(profile: BuiltinProfiles.deepseekV4Pro)
                == .meteredCredits)
        #expect(BillingShape.infer(profile: BuiltinProfiles.deepseekV4Flash)
                == .meteredCredits)
    }

    // MARK: - Custom profile routing by host

    private func makeCustom(id: String, host: String) -> UpstreamProfile {
        UpstreamProfile(
            id: id,
            displayName: id,
            baseURL: URL(string: "https://\(host)/v1")!,
            keychainAccount: id,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
    }

    @Test
    func customProfilePointingAtDeepSeekHostIsMetered() {
        let profile = makeCustom(id: "custom-ds", host: "api.deepseek.com")
        #expect(BillingShape.infer(profile: profile) == .meteredCredits)
    }

    @Test
    func customProfilePointingAtOpenRouterIsMetered() {
        let profile = makeCustom(id: "custom-or", host: "openrouter.ai")
        #expect(BillingShape.infer(profile: profile) == .meteredCredits)
    }

    @Test
    func customProfilePointingAtBuerAIIsIncludedQuota() {
        let profile = makeCustom(id: "custom-buer", host: "api.buerai.top")
        #expect(BillingShape.infer(profile: profile) == .includedQuota)
        // Bare-domain alias also matches.
        let profileBare = makeCustom(id: "custom-buer-bare", host: "buerai.top")
        #expect(BillingShape.infer(profile: profileBare) == .includedQuota)
    }

    @Test
    func customProfileWithUnknownHostFallsThroughToTokenOnly() {
        let profile = makeCustom(id: "custom-self-vllm", host: "vllm.example.invalid")
        #expect(BillingShape.infer(profile: profile) == .tokenOnly)
    }

    // MARK: - Spoofing guards (mirror the ProviderGroup rules)

    @Test
    func customProfilePointingAtAnthropicHostIsNOTSubscriptionWindow() {
        // The single Anthropic-OAuth subscription belongs to
        // `anthropic-native` only. A custom profile that happens to
        // proxy api.anthropic.com (e.g. dev reverse proxy) MUST
        // not silently land in `subscriptionWindow` — the
        // user's billing/quota relationship is with their
        // intermediary, not Anthropic.
        let profile = makeCustom(id: "custom-self-anthropic", host: "api.anthropic.com")
        let shape = BillingShape.infer(profile: profile)
        #expect(shape != .subscriptionWindow)
        // Specifically lands in tokenOnly because `api.anthropic.com`
        // is not in the registry's "billing" host sets.
        #expect(shape == .tokenOnly)
    }

    @Test
    func customProfileNamedDeepseekStillRouteByHost() {
        // A user-created profile named "deepseek-..." pointing at
        // a non-DeepSeek host stays tokenOnly — naming alone
        // doesn't credential us into a balance endpoint.
        let profile = makeCustom(id: "deepseek-fork", host: "fork.example.invalid")
        #expect(BillingShape.infer(profile: profile) == .tokenOnly)
    }

    // MARK: - Static helpers

    @Test
    func diagnosticLabelsAreDistinctAndStableForGrep() {
        let labels: [String] = [
            BillingShape.subscriptionWindow.diagnosticLabel,
            BillingShape.meteredCredits.diagnosticLabel,
            BillingShape.includedQuota.diagnosticLabel,
            BillingShape.tokenOnly.diagnosticLabel,
            BillingShape.unknown.diagnosticLabel,
        ]
        #expect(Set(labels).count == labels.count, "Labels must be distinct: \(labels)")
        // Anchor labels so log scrapers can grep stable strings.
        #expect(BillingShape.subscriptionWindow.diagnosticLabel == "subscription-window")
        #expect(BillingShape.meteredCredits.diagnosticLabel == "metered-credits")
        #expect(BillingShape.includedQuota.diagnosticLabel == "included-quota")
        #expect(BillingShape.tokenOnly.diagnosticLabel == "token-only")
        #expect(BillingShape.unknown.diagnosticLabel == "unknown")
    }

    @Test
    func displaysUSDFlagsMatchUIIntention() {
        // Subscription + included-quota deliberately suppress USD
        // columns — they're not metered in dollars.
        #expect(BillingShape.subscriptionWindow.displaysUSD == false)
        #expect(BillingShape.includedQuota.displaysUSD == false)
        #expect(BillingShape.unknown.displaysUSD == false)
        // Metered-credits is the canonical USD case.
        #expect(BillingShape.meteredCredits.displaysUSD == true)
        // tokenOnly returns true so the per-row pricing-metadata
        // path can render an estimate when the profile carries one;
        // rows without metadata fall back to "—" via UI logic.
        #expect(BillingShape.tokenOnly.displaysUSD == true)
    }
}
