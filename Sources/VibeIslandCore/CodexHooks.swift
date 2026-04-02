import Foundation

public enum CodexHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
}

public enum CodexPermissionMode: String, Codable, Sendable {
    case `default`
    case acceptEdits
    case plan
    case dontAsk
    case bypassPermissions
}

public struct CodexHookToolInput: Equatable, Codable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }
}

public enum CodexHookJSONValue: Equatable, Codable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: CodexHookJSONValue])
    case array([CodexHookJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CodexHookJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexHookJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct CodexHookPayload: Equatable, Codable, Sendable {
    public var cwd: String
    public var hookEventName: CodexHookEventName
    public var model: String
    public var permissionMode: CodexPermissionMode
    public var sessionID: String
    public var transcriptPath: String?
    public var source: String?
    public var turnID: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: CodexHookToolInput?
    public var toolResponse: CodexHookJSONValue?
    public var prompt: String?
    public var stopHookActive: Bool?
    public var lastAssistantMessage: String?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case hookEventName = "hook_event_name"
        case model
        case permissionMode = "permission_mode"
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case source
        case turnID = "turn_id"
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case prompt
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
    }

    public init(
        cwd: String,
        hookEventName: CodexHookEventName,
        model: String,
        permissionMode: CodexPermissionMode,
        sessionID: String,
        transcriptPath: String?,
        source: String? = nil,
        turnID: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        toolInput: CodexHookToolInput? = nil,
        toolResponse: CodexHookJSONValue? = nil,
        prompt: String? = nil,
        stopHookActive: Bool? = nil,
        lastAssistantMessage: String? = nil
    ) {
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.model = model
        self.permissionMode = permissionMode
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.source = source
        self.turnID = turnID
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.toolInput = toolInput
        self.toolResponse = toolResponse
        self.prompt = prompt
        self.stopHookActive = stopHookActive
        self.lastAssistantMessage = lastAssistantMessage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decode(String.self, forKey: .cwd)
        hookEventName = try container.decode(CodexHookEventName.self, forKey: .hookEventName)
        model = try container.decode(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(CodexPermissionMode.self, forKey: .permissionMode) ?? .default
        sessionID = try container.decode(String.self, forKey: .sessionID)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolUseID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
        toolInput = try container.decodeIfPresent(CodexHookToolInput.self, forKey: .toolInput)
        toolResponse = try container.decodeIfPresent(CodexHookJSONValue.self, forKey: .toolResponse)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        stopHookActive = try container.decodeIfPresent(Bool.self, forKey: .stopHookActive)
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
    }
}

public enum CodexHookDirective: Equatable, Codable, Sendable {
    case deny(reason: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case reason
    }

    private enum DirectiveType: String, Codable {
        case deny
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(DirectiveType.self, forKey: .type)

        switch type {
        case .deny:
            self = .deny(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .deny(reason):
            try container.encode(DirectiveType.deny, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public enum CodexHookOutputEncoder {
    private struct LegacyBlockOutput: Codable {
        var decision = "block"
        var reason: String
    }

    public static func standardOutput(for response: BridgeResponse) throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        switch response {
        case .acknowledged:
            return nil
        case let .codexHookDirective(directive):
            let data: Data

            switch directive {
            case let .deny(reason):
                data = try encoder.encode(LegacyBlockOutput(reason: reason))
            }

            var line = data
            line.append(UInt8(ascii: "\n"))
            return line
        }
    }
}

public extension CodexHookPayload {
    var workspaceName: String {
        let workspace = URL(fileURLWithPath: cwd).lastPathComponent
        return workspace.isEmpty ? "Workspace" : workspace
    }

    var sessionTitle: String {
        "Codex · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: "Terminal",
            workspaceName: workspaceName,
            paneTitle: "Codex \(sessionID.prefix(8))"
        )
    }

    var implicitStartSummary: String {
        switch hookEventName {
        case .sessionStart:
            if source == "resume" {
                return "Resumed Codex session in \(workspaceName)."
            }

            return "Started Codex session in \(workspaceName)."
        case .preToolUse:
            return "Codex is preparing a Bash command in \(workspaceName)."
        case .postToolUse:
            return "Codex reported a Bash result in \(workspaceName)."
        case .userPromptSubmit:
            return "Codex received a new prompt in \(workspaceName)."
        case .stop:
            return "Codex completed a turn in \(workspaceName)."
        }
    }

    var commandText: String? {
        toolInput?.command
    }

    var commandPreview: String? {
        clipped(commandText)
    }

    var promptPreview: String? {
        clipped(prompt)
    }

    var assistantMessagePreview: String? {
        clipped(lastAssistantMessage)
    }

    var toolResponsePreview: String? {
        guard let toolResponse else {
            return nil
        }

        return clipped(stringValue(for: toolResponse))
    }

    private func clipped(_ value: String?, limit: Int = 110) -> String? {
        guard let value else {
            return nil
        }

        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard collapsed.count > limit else {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return "\(collapsed[..<endIndex])…"
    }

    private func stringValue(for value: CodexHookJSONValue) -> String {
        switch value {
        case let .string(text):
            return text
        case let .number(number):
            return String(number)
        case let .boolean(flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case let .array(items):
            let rendered = items.map(stringValue(for:)).joined(separator: ", ")
            return "[\(rendered)]"
        case let .object(object):
            let rendered = object
                .keys
                .sorted()
                .map { key in
                    let value = object[key].map(stringValue(for:)) ?? "null"
                    return "\(key): \(value)"
                }
                .joined(separator: ", ")
            return "{\(rendered)}"
        }
    }
}
