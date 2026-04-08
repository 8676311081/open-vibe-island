import Foundation

// MARK: - Rule Type

public enum AutoResponseRuleType: String, Codable, Sendable, CaseIterable {
    case permission
    case question
}

// MARK: - Conditions

public struct RuleConditions: Equatable, Codable, Sendable {
    public var toolNames: [String]?
    public var pathPattern: String?
    public var agentTypes: [AgentTool]?
    public var titleKeywords: [String]?

    public init(
        toolNames: [String]? = nil,
        pathPattern: String? = nil,
        agentTypes: [AgentTool]? = nil,
        titleKeywords: [String]? = nil
    ) {
        self.toolNames = toolNames
        self.pathPattern = pathPattern
        self.agentTypes = agentTypes
        self.titleKeywords = titleKeywords
    }
}

// MARK: - Action

public enum RuleAction: Equatable, Codable, Sendable {
    case allow
    case deny(message: String?)
    case selectOption(index: Int)
    case selectByKeyword(String)
}

// MARK: - Rule

public struct AutoResponseRule: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var ruleType: AutoResponseRuleType
    public var conditions: RuleConditions
    public var action: RuleAction

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        ruleType: AutoResponseRuleType,
        conditions: RuleConditions,
        action: RuleAction
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.ruleType = ruleType
        self.conditions = conditions
        self.action = action
    }
}
