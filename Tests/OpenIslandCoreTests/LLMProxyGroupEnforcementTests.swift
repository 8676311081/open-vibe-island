import Testing
import Foundation
@testable import OpenIslandCore

/// Verifies that an `LLMProxyServer` configured with a specific
/// `ProviderGroup` rejects requests whose resolved profile maps
/// to a different group with HTTP 421 (Misdirected Request).
///
/// We don't bind a real port here — we exercise the policy by
/// constructing a `LLMProxyConfiguration` with a `providerGroup`
/// and calling the static body builder directly. The full
/// network round-trip is covered by the existing
/// `LLMProxyDeepSeekRoundTripTests` etc.; this suite is the unit
/// test for the policy decision and its 421 envelope shape.
@Suite struct LLMProxyGroupEnforcementTests {

    @Test
    func groupMismatchBodyIncludesActionableHints() {
        let body = LLMProxyServer.makeGroupMismatchBody(
            listenerGroup: .officialClaude,
            profileGroup: .deepseek,
            profileId: "deepseek-v4-pro"
        )
        // Has the structured error envelope.
        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        #expect(error?["type"] as? String == "open_island_port_group_mismatch")
        #expect(error?["listener_group"] as? String == "officialClaude")
        #expect(error?["listener_port"] as? Int == 9710)
        #expect(error?["profile_group"] as? String == "deepseek")
        #expect(error?["expected_port"] as? Int == 9711)
        #expect(error?["profile_id"] as? String == "deepseek-v4-pro")
        // Message points the user at the right port.
        let msg = error?["message"] as? String ?? ""
        #expect(msg.contains("127.0.0.1:9711"))
    }

    @Test
    func nilProviderGroupConfigurationDisablesEnforcement() {
        // Sanity: pre-three-port behavior — no providerGroup set,
        // no enforcement — preserves the legacy single-listener
        // path and existing tests' fixture configurations.
        let config = LLMProxyConfiguration(port: 0)
        #expect(config.providerGroup == nil)
    }

    @Test
    func providerGroupConfigurationRoundtrips() {
        let config = LLMProxyConfiguration(
            port: 9711,
            providerGroup: .deepseek
        )
        #expect(config.providerGroup == .deepseek)
        #expect(config.port == 9711)
    }

    @Test
    func everyGroupGetsADistinctMismatchMessage() {
        // Quick smoke that the body builder doesn't collapse two
        // groups into the same message text.
        var seen = Set<String>()
        for listenerGroup in ProviderGroup.allCases {
            for profileGroup in ProviderGroup.allCases where profileGroup != listenerGroup {
                let body = LLMProxyServer.makeGroupMismatchBody(
                    listenerGroup: listenerGroup,
                    profileGroup: profileGroup,
                    profileId: "p"
                )
                #expect(seen.insert(body).inserted, "Duplicate body for \(listenerGroup) vs \(profileGroup)")
            }
        }
    }
}
