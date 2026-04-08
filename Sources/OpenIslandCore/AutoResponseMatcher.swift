import Foundation

public enum AutoResponseMatcher {

    public static func match(
        rules: [AutoResponseRule],
        toolName: String?,
        affectedPath: String,
        agentTool: AgentTool,
        title: String?,
        isQuestion: Bool
    ) -> RuleAction? {
        let targetType: AutoResponseRuleType = isQuestion ? .question : .permission

        let matched = rules.filter { rule in
            guard rule.enabled, rule.ruleType == targetType else { return false }
            return conditionsMatch(rule.conditions, toolName: toolName, affectedPath: affectedPath, agentTool: agentTool, title: title)
        }

        guard !matched.isEmpty else { return nil }

        // Deny-takes-precedence
        for rule in matched {
            if case .deny = rule.action {
                return rule.action
            }
        }

        return matched.first?.action
    }

    private static func conditionsMatch(
        _ conditions: RuleConditions,
        toolName: String?,
        affectedPath: String,
        agentTool: AgentTool,
        title: String?
    ) -> Bool {
        if let toolNames = conditions.toolNames, !toolNames.isEmpty {
            guard let toolName, toolNames.contains(where: { $0.caseInsensitiveCompare(toolName) == .orderedSame }) else {
                return false
            }
        }

        if let pattern = conditions.pathPattern, !pattern.isEmpty {
            guard globMatch(pattern: pattern, path: affectedPath) else {
                return false
            }
        }

        if let agentTypes = conditions.agentTypes, !agentTypes.isEmpty {
            guard agentTypes.contains(agentTool) else {
                return false
            }
        }

        if let keywords = conditions.titleKeywords, !keywords.isEmpty {
            guard let title else { return false }
            let lowered = title.lowercased()
            guard keywords.contains(where: { lowered.contains($0.lowercased()) }) else {
                return false
            }
        }

        return true
    }

    private static func globMatch(pattern: String, path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let regexPattern = "^" + escaped.replacingOccurrences(of: "\\*", with: ".*") + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}
