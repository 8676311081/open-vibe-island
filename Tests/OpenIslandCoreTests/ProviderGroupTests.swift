import Testing
import Foundation
@testable import OpenIslandCore

/// Coverage for `ProviderGroup.infer(profile:)`. The mapping rules
/// are the security contract for the three-port routing scheme;
/// every `UpstreamProfile` shape (builtin / custom, hosts that
/// happen to look "official", future builtins) needs explicit
/// coverage so a regression here doesn't silently let, say, a
/// custom profile land on the official-Claude listener.
@Suite struct ProviderGroupTests {

    // MARK: - Builtins

    @Test
    func anthropicNativeBuiltinMapsToOfficialClaude() {
        let group = ProviderGroup.infer(profile: BuiltinProfiles.anthropicNative)
        #expect(group == .officialClaude)
    }

    @Test
    func deepseekV4ProBuiltinMapsToDeepseek() {
        let group = ProviderGroup.infer(profile: BuiltinProfiles.deepseekV4Pro)
        #expect(group == .deepseek)
    }

    @Test
    func deepseekV4FlashBuiltinMapsToDeepseek() {
        let group = ProviderGroup.infer(profile: BuiltinProfiles.deepseekV4Flash)
        #expect(group == .deepseek)
    }

    @Test
    func everyBuiltinHasACoveredGroup() {
        // Cheap regression guard: if someone adds a new builtin
        // and forgets to update `infer`, it lands in
        // `thirdParty` (the safe default). Make that explicit
        // here so the mistake is loud — every builtin must be
        // intentional, not accidental.
        for profile in BuiltinProfiles.all {
            let group = ProviderGroup.infer(profile: profile)
            switch profile.id {
            case "anthropic-native":
                #expect(group == .officialClaude)
            case let id where id.hasPrefix("deepseek-"):
                #expect(group == .deepseek)
            default:
                let msg = """
                New builtin "\(profile.id)" needs a ProviderGroup mapping. \
                Either add an explicit case in ProviderGroup.infer(profile:) \
                or document why thirdParty is the correct default.
                """
                Issue.record(Comment(rawValue: msg))
            }
        }
    }

    // MARK: - Custom profiles ALWAYS go to thirdParty

    @Test
    func customProfileWithThirdPartyHostMapsToThirdParty() {
        let profile = UpstreamProfile(
            id: "custom-buerai",
            displayName: "BuerAI",
            baseURL: URL(string: "https://api.buerai.top")!,
            keychainAccount: "custom-buerai",
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(ProviderGroup.infer(profile: profile) == .thirdParty)
    }

    @Test
    func customProfileSpoofingAnthropicHostStillMapsToThirdParty() {
        // The most dangerous reflex would be to look at baseURL.host
        // and route api.anthropic.com to officialClaude. A user can
        // create a custom profile with that exact host (typically a
        // local Anthropic-compatible reverse proxy that just happens
        // to point at the real domain in dev). Such a profile MUST
        // still land in thirdParty — the *endpoint owner* of a
        // custom profile is the user, not Anthropic.
        let profile = UpstreamProfile(
            id: "custom-self-hosted-anthropic",
            displayName: "My Anthropic Reverse Proxy",
            baseURL: URL(string: "https://api.anthropic.com")!,
            keychainAccount: "custom-self-hosted-anthropic",
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(ProviderGroup.infer(profile: profile) == .thirdParty)
    }

    @Test
    func customProfileNamedDeepseekStillMapsToThirdParty() {
        // Symmetric guard: a user who creates a custom profile
        // with id starting "deepseek-" doesn't get to land on
        // 9711 — only the registered builtins do.
        let profile = UpstreamProfile(
            id: "deepseek-fake-fork",
            displayName: "Sketchy Fork",
            baseURL: URL(string: "https://example.invalid")!,
            keychainAccount: "deepseek-fake-fork",
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(ProviderGroup.infer(profile: profile) == .thirdParty)
    }

    @Test
    func customProfileWithOpenRouterHostMapsToThirdParty() {
        // Even when OpenRouter is reverse-proxying official Claude
        // models, the billing / failure boundary is OpenRouter,
        // not Anthropic. Group reflects ownership.
        let profile = UpstreamProfile(
            id: "custom-openrouter",
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            keychainAccount: "custom-openrouter",
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(ProviderGroup.infer(profile: profile) == .thirdParty)
    }

    // MARK: - Static metadata

    @Test
    func defaultPortsAreDistinct() {
        let ports = Set(ProviderGroup.allCases.map(\.defaultLoopbackPort))
        #expect(ports.count == ProviderGroup.allCases.count)
    }

    @Test
    func officialClaudeStaysOn9710() {
        // Compatibility anchor: the existing `claude-3` shim and
        // every documented user environment hardcodes 9710 for
        // official Claude. The coordinator's lifecycle code can
        // override defaults, but this static fallback must never
        // drift from 9710 for the officialClaude case.
        #expect(ProviderGroup.officialClaude.defaultLoopbackPort == 9710)
        #expect(ProviderGroup.deepseek.defaultLoopbackPort == 9711)
        #expect(ProviderGroup.thirdParty.defaultLoopbackPort == 9712)
    }

    @Test
    func logTagsMatchRawValuesForGrep() {
        for group in ProviderGroup.allCases {
            #expect(group.logTag == group.rawValue)
        }
    }
}
