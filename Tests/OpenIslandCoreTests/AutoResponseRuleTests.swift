import Foundation
import Testing
@testable import OpenIslandCore

struct AutoResponseRuleTests {
    @Test
    func codableRoundTrip() throws {
        let rule = AutoResponseRule(
            name: "Allow all Read",
            enabled: true,
            ruleType: .permission,
            conditions: RuleConditions(toolNames: ["Read"]),
            action: .allow
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(AutoResponseRule.self, from: data)

        #expect(decoded.name == "Allow all Read")
        #expect(decoded.enabled == true)
        #expect(decoded.ruleType == .permission)
        #expect(decoded.conditions.toolNames == ["Read"])
        #expect(decoded.action == .allow)
    }

    @Test
    func codableRoundTripDenyAction() throws {
        let rule = AutoResponseRule(
            name: "Deny /etc",
            enabled: true,
            ruleType: .permission,
            conditions: RuleConditions(pathPattern: "/etc/*"),
            action: .deny(message: "Blocked by rule")
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(AutoResponseRule.self, from: data)

        #expect(decoded.action == .deny(message: "Blocked by rule"))
    }

    @Test
    func codableRoundTripQuestionActions() throws {
        let selectIndex = AutoResponseRule(
            name: "Always pick first",
            enabled: true,
            ruleType: .question,
            conditions: RuleConditions(),
            action: .selectOption(index: 0)
        )

        let selectKeyword = AutoResponseRule(
            name: "Pick production",
            enabled: true,
            ruleType: .question,
            conditions: RuleConditions(titleKeywords: ["deploy"]),
            action: .selectByKeyword("production")
        )

        let data1 = try JSONEncoder().encode(selectIndex)
        let decoded1 = try JSONDecoder().decode(AutoResponseRule.self, from: data1)
        #expect(decoded1.action == .selectOption(index: 0))

        let data2 = try JSONEncoder().encode(selectKeyword)
        let decoded2 = try JSONDecoder().decode(AutoResponseRule.self, from: data2)
        #expect(decoded2.action == .selectByKeyword("production"))
    }
}
