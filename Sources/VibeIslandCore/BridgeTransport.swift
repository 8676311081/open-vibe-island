import Darwin
import Foundation

public enum BridgeSocketLocation {
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/tmp/vibe-island-\(getuid()).sock")
    }

    public static func currentURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let path = environment["VIBE_ISLAND_SOCKET_PATH"], !path.isEmpty else {
            return defaultURL
        }

        return URL(fileURLWithPath: path)
    }

    public static func uniqueTestURL() -> URL {
        URL(fileURLWithPath: "/tmp/vibe-island-test-\(UUID().uuidString).sock")
    }
}

public enum BridgeTransportError: Error, LocalizedError {
    case alreadyConnected
    case notConnected
    case malformedEnvelope
    case responseTimedOut
    case listenerFailed(String)
    case socketPathTooLong
    case systemCallFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "The bridge client is already connected."
        case .notConnected:
            "The bridge client is not connected."
        case .malformedEnvelope:
            "The bridge transport received malformed data."
        case .responseTimedOut:
            "The local bridge timed out while waiting for a response."
        case let .listenerFailed(message):
            "The local bridge listener failed: \(message)"
        case .socketPathTooLong:
            "The Unix socket path is too long for `sockaddr_un`."
        case let .systemCallFailed(name, code):
            "\(name) failed with errno \(code)."
        }
    }
}

public struct BridgeHello: Equatable, Codable, Sendable {
    public var protocolVersion: Int
    public var serverLabel: String

    public init(protocolVersion: Int = 1, serverLabel: String = "local-bridge") {
        self.protocolVersion = protocolVersion
        self.serverLabel = serverLabel
    }
}

public enum BridgeClientRole: String, Codable, Sendable {
    case observer
}

public enum BridgeCommand: Equatable, Codable, Sendable {
    case registerClient(role: BridgeClientRole)
    case resetDemo
    case resolvePermission(sessionID: String, approved: Bool)
    case answerQuestion(sessionID: String, answer: String)
    case processCodexHook(CodexHookPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case role
        case sessionID
        case approved
        case answer
        case codexHook
    }

    private enum CommandType: String, Codable {
        case registerClient
        case resetDemo
        case resolvePermission
        case answerQuestion
        case processCodexHook
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CommandType.self, forKey: .type)

        switch type {
        case .registerClient:
            self = .registerClient(role: try container.decode(BridgeClientRole.self, forKey: .role))
        case .resetDemo:
            self = .resetDemo
        case .resolvePermission:
            self = .resolvePermission(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                approved: try container.decode(Bool.self, forKey: .approved)
            )
        case .answerQuestion:
            self = .answerQuestion(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                answer: try container.decode(String.self, forKey: .answer)
            )
        case .processCodexHook:
            self = .processCodexHook(try container.decode(CodexHookPayload.self, forKey: .codexHook))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .registerClient(role):
            try container.encode(CommandType.registerClient, forKey: .type)
            try container.encode(role, forKey: .role)
        case .resetDemo:
            try container.encode(CommandType.resetDemo, forKey: .type)
        case let .resolvePermission(sessionID, approved):
            try container.encode(CommandType.resolvePermission, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(approved, forKey: .approved)
        case let .answerQuestion(sessionID, answer):
            try container.encode(CommandType.answerQuestion, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(answer, forKey: .answer)
        case let .processCodexHook(payload):
            try container.encode(CommandType.processCodexHook, forKey: .type)
            try container.encode(payload, forKey: .codexHook)
        }
    }
}

public enum BridgeResponse: Equatable, Codable, Sendable {
    case acknowledged
    case codexHookDirective(CodexHookDirective)

    private enum CodingKeys: String, CodingKey {
        case type
        case directive
    }

    private enum ResponseType: String, Codable {
        case acknowledged
        case codexHookDirective
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ResponseType.self, forKey: .type)

        switch type {
        case .acknowledged:
            self = .acknowledged
        case .codexHookDirective:
            self = .codexHookDirective(try container.decode(CodexHookDirective.self, forKey: .directive))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .acknowledged:
            try container.encode(ResponseType.acknowledged, forKey: .type)
        case let .codexHookDirective(directive):
            try container.encode(ResponseType.codexHookDirective, forKey: .type)
            try container.encode(directive, forKey: .directive)
        }
    }
}

public enum BridgeEnvelope: Equatable, Codable, Sendable {
    case hello(BridgeHello)
    case event(AgentEvent)
    case command(BridgeCommand)
    case response(BridgeResponse)

    private enum CodingKeys: String, CodingKey {
        case type
        case hello
        case event
        case command
        case response
    }

    private enum EnvelopeType: String, Codable {
        case hello
        case event
        case command
        case response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EnvelopeType.self, forKey: .type)

        switch type {
        case .hello:
            self = .hello(try container.decode(BridgeHello.self, forKey: .hello))
        case .event:
            self = .event(try container.decode(AgentEvent.self, forKey: .event))
        case .command:
            self = .command(try container.decode(BridgeCommand.self, forKey: .command))
        case .response:
            self = .response(try container.decode(BridgeResponse.self, forKey: .response))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .hello(payload):
            try container.encode(EnvelopeType.hello, forKey: .type)
            try container.encode(payload, forKey: .hello)
        case let .event(payload):
            try container.encode(EnvelopeType.event, forKey: .type)
            try container.encode(payload, forKey: .event)
        case let .command(payload):
            try container.encode(EnvelopeType.command, forKey: .type)
            try container.encode(payload, forKey: .command)
        case let .response(payload):
            try container.encode(EnvelopeType.response, forKey: .type)
            try container.encode(payload, forKey: .response)
        }
    }
}

public enum BridgeCodec {
    private static let newline = UInt8(ascii: "\n")

    public static func encodeLine(_ envelope: BridgeEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        var data = try encoder.encode(envelope)
        data.append(newline)
        return data
    }

    public static func decodeLines(from buffer: inout Data) throws -> [BridgeEnvelope] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        var messages: [BridgeEnvelope] = []

        while let newlineIndex = buffer.firstIndex(of: newline) {
            let line = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty else {
                continue
            }

            do {
                let message = try decoder.decode(BridgeEnvelope.self, from: Data(line))
                messages.append(message)
            } catch {
                throw BridgeTransportError.malformedEnvelope
            }
        }

        return messages
    }
}

func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(path.utf8)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)

    guard pathBytes.count < maxPathLength else {
        throw BridgeTransportError.socketPathTooLong
    }

    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)

        for (index, byte) in pathBytes.enumerated() {
            rawBuffer[index] = byte
        }
    }

    let length = socklen_t(
        MemoryLayout.size(ofValue: address.sun_len) +
        MemoryLayout.size(ofValue: address.sun_family) +
        pathBytes.count + 1
    )

    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            try body(sockaddrPointer, length)
        }
    }
}

func makeSocketNonBlocking(_ fileDescriptor: Int32) throws {
    let currentFlags = fcntl(fileDescriptor, F_GETFL)
    guard currentFlags != -1 else {
        throw BridgeTransportError.systemCallFailed("fcntl(F_GETFL)", errno)
    }

    guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
        throw BridgeTransportError.systemCallFailed("fcntl(F_SETFL)", errno)
    }
}

func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    var remaining = data[...]

    while !remaining.isEmpty {
        let bytesWritten = remaining.withUnsafeBytes { rawBuffer -> Int in
            let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return write(fileDescriptor, baseAddress, rawBuffer.count)
        }

        if bytesWritten > 0 {
            remaining.removeFirst(bytesWritten)
            continue
        }

        if bytesWritten == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            usleep(1_000)
            continue
        }

        throw BridgeTransportError.systemCallFailed("write", errno)
    }
}
