import Foundation
import Testing
@testable import OpenIslandCore

/// Stub resolver for the pricing fallback path — returns whatever
/// profile the test hands in, avoiding UserDefaults + real store
/// plumbing.
private struct StubProfileResolver: UpstreamProfileResolver, Sendable {
    let profile: UpstreamProfile
    func currentActiveProfile() -> UpstreamProfile { profile }
    func profileMatching(url: URL) -> UpstreamProfile? { nil }
}

/// Tests for 4.6.3: `LLMPricing.costUSD(model:usage:profileResolver:)`
/// — the resolver-aware overload that falls back to
/// `ProfileCostMetadata` when the static `LLMPricing.table` has no
/// entry for a model id (e.g. `deepseek-v4-pro` after body rewrite).
struct LLMPricingProfileFallbackTests {
    private static func makeResolver(active: UpstreamProfile) -> any UpstreamProfileResolver {
        StubProfileResolver(profile: active)
    }

    /// 1000 input + 2000 output, no cache read, DSV4 Pro discounted rates
    /// ($0.435/$0.87 per Mtok). Expected: (1000*0.435 + 2000*0.87) / 1e6
    /// = (435 + 1740) / 1e6 = 2175/1e6 = 0.002175
    @Test
    func costComputedForDeepSeekV4Pro() {
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let usage = TokenUsage(input: 1000, cacheWrite: 0, cacheRead: 0, output: 2000)
        let cost = LLMPricing.costUSD(
            model: "deepseek-v4-pro",
            usage: usage,
            profileResolver: resolver
        )
        #expect(cost != nil)
        let expected = (Double(1000) * 0.435 + Double(2000) * 0.87) / 1_000_000.0
        #expect(abs((cost ?? 0) - expected) < 0.0000001)
    }

    /// DSV4 Flash: $0.14/$0.28 per Mtok.
    @Test
    func costComputedForDeepSeekV4Flash() {
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Flash)
        let usage = TokenUsage(input: 5000, cacheWrite: 1000, cacheRead: 0, output: 3000)
        let cost = LLMPricing.costUSD(
            model: "deepseek-v4-flash",
            usage: usage,
            profileResolver: resolver
        )
        #expect(cost != nil)
        // input = 5000 + 1000 (cacheWrite) = 6000 billed at input rate
        let expected = (Double(6000) * 0.14 + Double(3000) * 0.28) / 1_000_000.0
        #expect(abs((cost ?? 0) - expected) < 0.0000001)
    }

    /// Model that's neither in the static table nor matched by
    /// active profile's modelOverride → nil (unpriced).
    @Test
    func costNilWhenModelNotInAnyTable() {
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let usage = TokenUsage(input: 1000, output: 1000)
        let cost = LLMPricing.costUSD(
            model: "some-fake-model-v7",
            usage: usage,
            profileResolver: resolver
        )
        #expect(cost == nil)
    }

    /// Profile resolver is nil → same behavior as the original
    /// single-arg `costUSD`. Must not crash (nil unwrap).
    @Test
    func nilResolverFallsBackGracefully() {
        let usage = TokenUsage(input: 1000, output: 1000)
        let cost = LLMPricing.costUSD(
            model: "deepseek-v4-pro",
            usage: usage,
            profileResolver: nil
        )
        #expect(cost == nil) // not in static table, no resolver → nil
    }

    /// Verify the discount expiry gate: construct a profile whose
    /// discount window closed yesterday but list prices are filed.
    /// The cost computation should use list prices, not the stale
    /// discounted rates.
    @Test
    func discountExpiryFallbackUsesListPrices() {
        let pastExpiry = Date().addingTimeInterval(-86_400) // discount expired yesterday
        let expiredMeta = ProfileCostMetadata(
            inputUSDPerMtok: 0.435,
            outputUSDPerMtok: 0.87,
            cacheReadUSDPerMtok: 0.003625,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: pastExpiry,
            listInputUSDPerMtok: 1.74,
            listOutputUSDPerMtok: 3.48
        )
        let profile = UpstreamProfile(
            id: "deepseek-v4-pro",
            displayName: "x",
            baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
            keychainAccount: "deepseek",
            modelOverride: "deepseek-v4-pro",
            isCustom: false,
            costMetadata: expiredMeta
        )
        let resolver = Self.makeResolver(active: profile)
        let usage = TokenUsage(input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 1_000_000)
        let cost = LLMPricing.costUSD(
            model: "deepseek-v4-pro",
            usage: usage,
            profileResolver: resolver
        )
        #expect(cost != nil)
        // 1M input × $1.74 + 1M output × $3.48 = $1.74 + $3.48 = $5.22
        let expected = 1.74 + 3.48
        #expect(abs((cost ?? 0) - expected) < 0.0001)
        // Sanity: should be higher than the discounted rate ($0.435+$0.87=$1.302)
        #expect((cost ?? 0) > 1.5)
    }

    /// Anthropic models in the static table must still resolve through
    /// the table, not through the resolver (even when the resolver is
    /// wired and points at a non-Anthropic profile). ProfileCostMetadata
    /// is only a fallback, never a replacement.
    @Test
    func anthropicStaticTablePricingIsUnaffectedByResolver() {
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let usage = TokenUsage(input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 0)
        let cost = LLMPricing.costUSD(
            model: "claude-opus-4-7",
            usage: usage,
            profileResolver: resolver
        )
        #expect(cost != nil)
        // Opus 4.7 input: $5.00/Mtok → 1M tokens = $5.00
        let expected = 5.00
        #expect(abs((cost ?? 0) - expected) < 0.01)
        // Must NOT be the DeepSeek V4 Pro rate (which would be $0.435)
        #expect(abs((cost ?? 0) - 0.435) > 1.0)
    }

    /// `claude-opus-4-7[1m]` is the 1M-context SKU suffix Claude CLI
    /// emits. The prefix matcher's `key + "-"` delimiter doesn't
    /// catch `[`-separated suffixes, so bracketed variants need
    /// explicit table rows. Verify the row added in 4.6.3b.
    @Test
    func pricingResolvesBracketSuffixOpus47() {
        let usage = TokenUsage(input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 0)
        let cost = LLMPricing.costUSD(model: "claude-opus-4-7[1m]", usage: usage)
        #expect(cost != nil)
        let expected = 5.00 // same as bare claude-opus-4-7
        #expect(abs((cost ?? 0) - expected) < 0.01)
    }

    /// `claude-sonnet-4-6[1m]` — same bracket form, Sonnet pricing.
    @Test
    func pricingResolvesBracketSuffixSonnet46() {
        let usage = TokenUsage(input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 0)
        let cost = LLMPricing.costUSD(model: "claude-sonnet-4-6[1m]", usage: usage)
        #expect(cost != nil)
        let expected = 3.00 // same as bare claude-sonnet-4-6
        #expect(abs((cost ?? 0) - expected) < 0.01)
    }
}
