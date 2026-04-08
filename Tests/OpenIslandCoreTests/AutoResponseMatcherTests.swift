import Foundation
import Testing
@testable import OpenIslandCore

struct AutoResponseMatcherTests {

    @Test
    func matchesPermissionByToolName() {
        let rules = [
            AutoResponseRule(
                name: "Allow Read",
                ruleType: .permission,
                conditions: RuleConditions(toolNames: ["Read"]),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Read", affectedPath: "/some/path",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == .allow)
    }

    @Test
    func noMatchWhenToolNameDiffers() {
        let rules = [
            AutoResponseRule(
                name: "Allow Read",
                ruleType: .permission,
                conditions: RuleConditions(toolNames: ["Read"]),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Bash", affectedPath: "/some/path",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == nil)
    }

    @Test
    func matchesPermissionByPathGlob() {
        let rules = [
            AutoResponseRule(
                name: "Allow project files",
                ruleType: .permission,
                conditions: RuleConditions(pathPattern: "/Users/qwen/projects/*"),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Edit",
            affectedPath: "/Users/qwen/projects/app/main.swift",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == .allow)
    }

    @Test
    func noMatchWhenPathOutsideGlob() {
        let rules = [
            AutoResponseRule(
                name: "Allow project files",
                ruleType: .permission,
                conditions: RuleConditions(pathPattern: "/Users/qwen/projects/*"),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Edit", affectedPath: "/etc/hosts",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == nil)
    }

    @Test
    func matchesPermissionByAgentType() {
        let rules = [
            AutoResponseRule(
                name: "Allow Claude Code only",
                ruleType: .permission,
                conditions: RuleConditions(agentTypes: [.claudeCode]),
                action: .allow
            ),
        ]
        let resultCC = AutoResponseMatcher.match(
            rules: rules, toolName: "Read", affectedPath: "/tmp/x",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(resultCC == .allow)

        let resultCodex = AutoResponseMatcher.match(
            rules: rules, toolName: "Read", affectedPath: "/tmp/x",
            agentTool: .codex, title: nil, isQuestion: false
        )
        #expect(resultCodex == nil)
    }

    @Test
    func matchesWithMultipleConditionsAND() {
        let rules = [
            AutoResponseRule(
                name: "Allow Read in projects for CC",
                ruleType: .permission,
                conditions: RuleConditions(
                    toolNames: ["Read"],
                    pathPattern: "/Users/qwen/projects/*",
                    agentTypes: [.claudeCode]
                ),
                action: .allow
            ),
        ]
        let result1 = AutoResponseMatcher.match(
            rules: rules, toolName: "Read",
            affectedPath: "/Users/qwen/projects/foo.swift",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result1 == .allow)

        let result2 = AutoResponseMatcher.match(
            rules: rules, toolName: "Bash",
            affectedPath: "/Users/qwen/projects/foo.swift",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result2 == nil)
    }

    @Test
    func matchesQuestionByKeyword() {
        let rules = [
            AutoResponseRule(
                name: "Auto-select for deploy",
                ruleType: .question,
                conditions: RuleConditions(titleKeywords: ["deploy"]),
                action: .selectOption(index: 0)
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: nil, affectedPath: "",
            agentTool: .claudeCode, title: "Choose deploy target",
            isQuestion: true
        )
        #expect(result == .selectOption(index: 0))
    }

    @Test
    func questionRuleDoesNotMatchPermission() {
        let rules = [
            AutoResponseRule(
                name: "Auto-select",
                ruleType: .question,
                conditions: RuleConditions(),
                action: .selectOption(index: 0)
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Read", affectedPath: "/tmp/x",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == nil)
    }

    @Test
    func denyTakesPrecedenceOverAllow() {
        let rules = [
            AutoResponseRule(
                name: "Allow Bash",
                ruleType: .permission,
                conditions: RuleConditions(toolNames: ["Bash"]),
                action: .allow
            ),
            AutoResponseRule(
                name: "Deny /etc",
                ruleType: .permission,
                conditions: RuleConditions(pathPattern: "/etc/*"),
                action: .deny(message: "Blocked")
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Bash", affectedPath: "/etc/hosts",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == .deny(message: "Blocked"))
    }

    @Test
    func disabledRulesAreSkipped() {
        let rules = [
            AutoResponseRule(
                name: "Allow Read",
                enabled: false,
                ruleType: .permission,
                conditions: RuleConditions(toolNames: ["Read"]),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Read", affectedPath: "/tmp/x",
            agentTool: .claudeCode, title: nil, isQuestion: false
        )
        #expect(result == nil)
    }

    @Test
    func emptyConditionsMatchesEverything() {
        let rules = [
            AutoResponseRule(
                name: "Allow all permissions",
                ruleType: .permission,
                conditions: RuleConditions(),
                action: .allow
            ),
        ]
        let result = AutoResponseMatcher.match(
            rules: rules, toolName: "Bash", affectedPath: "/anything",
            agentTool: .codex, title: nil, isQuestion: false
        )
        #expect(result == .allow)
    }
}
