import AppKit
import Foundation
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

/// Coverage for the pure state-derivation helpers in
/// `ModelRoutingDerivation`. The SwiftUI pane itself is exercised
/// at UI smoke time; here we test the logic that decides what each
/// card looks like and when the discount-countdown chip fires.
struct ModelRoutingPaneTests {
    // MARK: - cardState

    @Test
    func anthropicNativePassthroughIsBlockedForMaxOAuth() {
        // keychainAccount == nil + baseURL == api.anthropic.com → blocked.
        // Max/Pro OAuth can't pass through the proxy because Anthropic
        // enforces client identity end-to-end.
        let state = ModelRoutingDerivation.cardState(
            profile: BuiltinProfiles.anthropicNative,
            activeProfileId: "anthropic-native",
            hasCredentialFor: { _ in false }
        )
        #expect(state == .blockedBySubscription)
    }

    @Test
    func anthropicNativeBlockedEvenWhenInactive() {
        // Same profile, different active — blocked state is returned
        // regardless of active/inactive status.
        let state = ModelRoutingDerivation.cardState(
            profile: BuiltinProfiles.anthropicNative,
            activeProfileId: "deepseek-v4-pro",
            hasCredentialFor: { _ in false }
        )
        #expect(state == .blockedBySubscription)
    }

    @Test
    func missingKeyShowsConfigureCTA() {
        // DSV4 Pro is inactive AND has no stored key — cardState
        // must drive UI to "Configure API key" path, not "Switch".
        let state = ModelRoutingDerivation.cardState(
            profile: BuiltinProfiles.deepseekV4Pro,
            activeProfileId: "anthropic-native",
            hasCredentialFor: { _ in false }
        )
        #expect(state == .inactiveAndMissingKey)
    }

    @Test
    func errorStateWhenActiveProfileMissingItsKey() {
        // Defensive case (shouldn't occur because setActiveProfile
        // ought to validate). If somehow active = DeepSeek but no
        // key, surface as .errorActiveButMissingKey so the pane
        // shows the warning banner.
        let state = ModelRoutingDerivation.cardState(
            profile: BuiltinProfiles.deepseekV4Pro,
            activeProfileId: "deepseek-v4-pro",
            hasCredentialFor: { _ in false }
        )
        #expect(state == .errorActiveButMissingKey)
    }

    // MARK: - discountState + countdown threshold

    @Test
    func discountCountdownDisplaysWhenWithin30Days() {
        // Construct a profile with discountExpiresAt 5 days from
        // "now". Both the days-remaining computation and the
        // shouldShowCountdown gate must fire.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expires = Calendar(identifier: .gregorian).date(byAdding: .day, value: 5, to: now)!
        let metadata = ProfileCostMetadata(
            inputUSDPerMtok: 0.1,
            outputUSDPerMtok: 0.2,
            cacheReadUSDPerMtok: 0.001,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: expires
        )
        let state = ModelRoutingDerivation.discountState(metadata: metadata, now: now)
        guard case let .active(days) = state else {
            Issue.record("expected .active(_), got \(state)")
            return
        }
        #expect(days == 5)
        #expect(ModelRoutingDerivation.shouldShowCountdown(state))
    }

    @Test
    func discountHiddenAfterExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expires = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now)!
        let metadata = ProfileCostMetadata(
            inputUSDPerMtok: 0.1,
            outputUSDPerMtok: 0.2,
            cacheReadUSDPerMtok: nil,
            contextWindowTokens: 100,
            discountExpiresAt: expires
        )
        let state = ModelRoutingDerivation.discountState(metadata: metadata, now: now)
        #expect(state == .expired)
        #expect(!ModelRoutingDerivation.shouldShowCountdown(state))
    }

    @Test
    func discountHiddenWhenWindowFurtherThanThirtyDays() {
        // 60 days out — discount is ACTIVE but the chip should not
        // surface yet (no need to nag the user months in advance).
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expires = Calendar(identifier: .gregorian).date(byAdding: .day, value: 60, to: now)!
        let metadata = ProfileCostMetadata(
            inputUSDPerMtok: 0.1,
            outputUSDPerMtok: 0.2,
            cacheReadUSDPerMtok: nil,
            contextWindowTokens: 100,
            discountExpiresAt: expires
        )
        let state = ModelRoutingDerivation.discountState(metadata: metadata, now: now)
        guard case let .active(days) = state else {
            Issue.record("expected .active, got \(state)")
            return
        }
        #expect(days == 60)
        #expect(!ModelRoutingDerivation.shouldShowCountdown(state))
    }

    // MARK: - effective price post-expiry

    @Test
    func effectivePriceFallsBackToListAfterExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expires = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now)!
        let metadata = ProfileCostMetadata(
            inputUSDPerMtok: 0.435, // discounted
            outputUSDPerMtok: 0.87,
            cacheReadUSDPerMtok: nil,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: expires,
            listInputUSDPerMtok: 1.74,
            listOutputUSDPerMtok: 3.48
        )
        let inputPrice = ModelRoutingDerivation.effectiveInputPrice(metadata: metadata, now: now)
        let outputPrice = ModelRoutingDerivation.effectiveOutputPrice(metadata: metadata, now: now)
        // Discount has expired and listInputUSDPerMtok > 0, so the
        // post-expiry list price is what the card should display.
        #expect(inputPrice == 1.74)
        #expect(outputPrice == 3.48)
    }

    @Test
    func effectivePriceSticksWithDiscountWhenWindowActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expires = Calendar(identifier: .gregorian).date(byAdding: .day, value: 10, to: now)!
        let metadata = ProfileCostMetadata(
            inputUSDPerMtok: 0.435,
            outputUSDPerMtok: 0.87,
            cacheReadUSDPerMtok: nil,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: expires,
            listInputUSDPerMtok: 1.74,
            listOutputUSDPerMtok: 3.48
        )
        let inputPrice = ModelRoutingDerivation.effectiveInputPrice(metadata: metadata, now: now)
        #expect(inputPrice == 0.435)
    }

    // MARK: - deep-link

    @MainActor
    @Test
    func deepLinkOpensModelRoutingTab() {
        // `openModelRouting()` calls into AppKit's `NSApp.activate` /
        // window discovery, which is fine in a real GUI process but
        // crashes in a headless XCTest runner if `NSApp` hasn't been
        // initialized. Touching `NSApplication.shared` before the
        // call ensures the singleton exists.
        _ = NSApplication.shared
        let model = AppModel()
        #expect(model.selectedSettingsTab == nil)
        model.openModelRouting()
        #expect(model.selectedSettingsTab == .modelRouting)
    }
}
