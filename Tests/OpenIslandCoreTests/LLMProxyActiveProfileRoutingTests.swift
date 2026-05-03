import Foundation
import Testing
@testable import OpenIslandCore

/// File-private mock URLProtocol — captures every outbound request
/// the proxy makes so the test can assert "the URL we forwarded to
/// matched the active profile's baseURL". Deliberately separate from
/// `MockUpstreamProtocol` (used by `LLMProxyServerIntegrationTests`):
/// that file's mock shares a process-global responder that can race
/// across suites. Keeping this one file-private + `@Suite(.serialized)`
/// means only this suite can register on it, and only one test from
/// the suite at a time.
private final class CaptureMockProtocol: URLProtocol {
    struct Capture: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
    }

    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Capture] = []
    nonisolated(unsafe) private static var enabled: Bool = false

    static func enable() {
        lock.lock(); defer { lock.unlock() }
        enabled = true
        captured.removeAll()
    }

    static func disable() {
        lock.lock(); defer { lock.unlock() }
        enabled = false
        captured.removeAll()
    }

    private static func isEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    static func appendCapture(_ c: Capture) {
        lock.lock(); defer { lock.unlock() }
        captured.append(c)
    }

    static func currentCaptures() -> [Capture] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool {
        isEnabled()
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headerSnapshot: [String: String] = [:]
        for (k, v) in (request.allHTTPHeaderFields ?? [:]) {
            headerSnapshot[k] = v
        }
        Self.appendCapture(Capture(
            url: request.url ?? URL(string: "missing:")!,
            method: request.httpMethod ?? "?",
            headers: headerSnapshot
        ))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"x","content":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Tests for Phase 4.6.1: `LLMProxyServer` must forward Anthropic-
/// format requests to the **active profile's** `baseURL`, not to
/// the static `configuration.anthropicUpstream` field. The static
/// field survives only as the self-hosted-gateway escape hatch when
/// active = anthropic-native AND the user has explicitly overridden
/// it.
@Suite(.serialized)
struct LLMProxyActiveProfileRoutingTests {
    private static func makeStore(suiteName: String) -> UpstreamProfileStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UpstreamProfileStore(userDefaults: defaults)
    }

    private static func makeServer(
        profileResolver: any UpstreamProfileResolver,
        anthropicUpstream: URL = URL(string: "https://api.anthropic.com")!
    ) async throws -> (LLMProxyServer, UInt16) {
        CaptureMockProtocol.enable()
        let server = LLMProxyServer(
            configuration: LLMProxyConfiguration(
                port: 0,
                anthropicUpstream: anthropicUpstream,
                openAIUpstream: URL(string: "https://api.openai.com")!
            ),
            additionalProtocolClasses: [CaptureMockProtocol.self],
            profileResolver: profileResolver
        )
        try server.start()
        try await server.waitUntilReady(timeout: 3)
        guard let port = server.actualPort else {
            throw NSError(domain: "test", code: -1)
        }
        return (server, port)
    }

    private static func makeClientSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }

    private static func sendAnthropicRequest(port: UInt16) async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","max_tokens":1,"messages":[]}"#.utf8)
        _ = try await Self.makeClientSession().data(for: req)
    }

    @Test
    func routingFollowsActiveProfileBaseURL() async throws {
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)
        let (server, port) = try await Self.makeServer(profileResolver: store)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequest(port: port)

        let captures = CaptureMockProtocol.currentCaptures()
        #expect(captures.count == 1)
        // The expected outbound URL combines DeepSeek's baseURL
        // (https://api.deepseek.com/anthropic) with the inbound path
        // (/v1/messages) — final URL should target DeepSeek, NOT
        // api.anthropic.com (which `configuration.anthropicUpstream`
        // pinned).
        let outboundURL = captures.first?.url
        #expect(outboundURL?.host == "api.deepseek.com")
        #expect(outboundURL?.path == "/anthropic/v1/messages")
    }

    @Test
    func activeProfileSwitchUpdatesNextRequestURL() async throws {
        // Two consecutive requests with a profile switch in between
        // — the server reads `currentActiveProfile()` per request, so
        // the second request must observe the new profile without a
        // server restart or `rebuildServer()` cycle.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        // Default state = anthropic-native (no setActiveProfile call).
        let (server, port) = try await Self.makeServer(profileResolver: store)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequest(port: port)
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Flash.id)
        try await Self.sendAnthropicRequest(port: port)

        let captures = CaptureMockProtocol.currentCaptures()
        #expect(captures.count == 2)
        #expect(captures[0].url.host == "api.anthropic.com")
        #expect(captures[1].url.host == "api.deepseek.com")
    }

    @Test
    func anthropicUpstreamOverrideAppliesOnlyForAnthropicNative() async throws {
        // Self-hosted-gateway escape hatch:
        //   active = anthropic-native + custom anthropicUpstream
        //   → use custom (the user's gateway).
        // When active != anthropic-native, the custom anthropicUpstream
        // is irrelevant — profile's baseURL wins.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let customGateway = URL(string: "https://my-anthropic-proxy.example/api")!

        // Round 1: active = anthropic-native, custom upstream → custom wins.
        let storeNative = Self.makeStore(suiteName: suiteName + ".native")
        let (server1, port1) = try await Self.makeServer(
            profileResolver: storeNative,
            anthropicUpstream: customGateway
        )
        try await Self.sendAnthropicRequest(port: port1)
        let nativeURL = CaptureMockProtocol.currentCaptures().first?.url
        server1.stop()
        CaptureMockProtocol.disable()
        UserDefaults().removePersistentDomain(forName: suiteName + ".native")
        #expect(nativeURL?.host == "my-anthropic-proxy.example")
        #expect(nativeURL?.path == "/api/v1/messages")

        // Round 2: active = deepseek-v4-pro, same custom upstream
        // configured → custom is IGNORED, deepseek wins.
        let storeDeepseek = Self.makeStore(suiteName: suiteName + ".deepseek")
        try storeDeepseek.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)
        let (server2, port2) = try await Self.makeServer(
            profileResolver: storeDeepseek,
            anthropicUpstream: customGateway
        )
        defer {
            server2.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName + ".deepseek")
        }
        try await Self.sendAnthropicRequest(port: port2)
        let deepseekURL = CaptureMockProtocol.currentCaptures().first?.url
        #expect(deepseekURL?.host == "api.deepseek.com")
    }

    @Test
    func activeProfileChangeIsThreadSafeUnderConcurrentRequests() async throws {
        // Concurrent: 30 client requests, with a background task
        // flipping the active profile every few ms. The proxy reads
        // `currentActiveProfile()` per request inside its own queue,
        // and the store's NSLock guards the read against the writer.
        // Test passes if (a) no crash, (b) every captured URL points
        // at one of the two valid hosts (no torn reads / garbage).
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        let (server, port) = try await Self.makeServer(profileResolver: store)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        let flipper = Task<Void, Never> {
            for _ in 0..<60 {
                try? store.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)
                try? await Task.sleep(nanoseconds: 1_000_000)
                try? store.setActiveProfile(BuiltinProfiles.anthropicNative.id)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    try? await Self.sendAnthropicRequest(port: port)
                }
            }
        }
        flipper.cancel()
        _ = await flipper.value

        let captures = CaptureMockProtocol.currentCaptures()
        #expect(captures.count == 30)
        let validHosts: Set<String> = ["api.anthropic.com", "api.deepseek.com"]
        for capture in captures {
            #expect(validHosts.contains(capture.url.host ?? ""))
        }
    }

    @Test
    func initWithoutResolverFallsBackToConfiguration() async throws {
        // Backward compat — older test setups (LLMProxyServer
        // Integration's existing makeServer) construct without
        // injecting a resolver. They must continue to forward to
        // `configuration.anthropicUpstream` exactly as before.
        CaptureMockProtocol.enable()
        let configuredUpstream = URL(string: "https://legacy.anthropic.example")!
        let server = LLMProxyServer(
            configuration: LLMProxyConfiguration(
                port: 0,
                anthropicUpstream: configuredUpstream,
                openAIUpstream: URL(string: "https://api.openai.com")!
            ),
            additionalProtocolClasses: [CaptureMockProtocol.self]
            // profileResolver: nil (default — backward compat)
        )
        try server.start()
        try await server.waitUntilReady(timeout: 3)
        guard let port = server.actualPort else {
            throw NSError(domain: "test", code: -1)
        }
        defer {
            server.stop()
            CaptureMockProtocol.disable()
        }
        try await Self.sendAnthropicRequest(port: port)
        let captures = CaptureMockProtocol.currentCaptures()
        #expect(captures.count == 1)
        #expect(captures.first?.url.host == "legacy.anthropic.example")
    }
}
