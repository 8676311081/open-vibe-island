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

    static func waitForCaptureCount(_ count: Int, timeout: TimeInterval = 2) async -> [Capture] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = currentCaptures()
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return currentCaptures()
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

    /// T3 helper — same as `sendAnthropicRequest` but the URL carries
    /// the per-invocation profile sentinel `/_oi/profile/<id>/`
    /// before the actual `/v1/messages` path. This mirrors what
    /// `claude-3` (T5) will do when `OI_PROFILE` is set.
    private static func sendAnthropicRequestWithOverride(
        port: UInt16,
        overrideId: String
    ) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/_oi/profile/\(overrideId)/v1/messages")!
        var req = URLRequest(url: url)
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
        // Use an explicit Anthropic-compatible gateway so this test
        // remains fully intercepted by CaptureMockProtocol instead of
        // touching the real api.anthropic.com default domain.
        let nativeGateway = URL(string: "https://native-gateway.example")!
        let (server, port) = try await Self.makeServer(
            profileResolver: store,
            anthropicUpstream: nativeGateway
        )
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequest(port: port)
        _ = await CaptureMockProtocol.waitForCaptureCount(1)
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Flash.id)
        try await Self.sendAnthropicRequest(port: port)

        let captures = await CaptureMockProtocol.waitForCaptureCount(2)
        #expect(captures.count == 2)
        #expect(captures[0].url.host == "native-gateway.example")
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
        let nativeGateway = URL(string: "https://native-gateway.example")!
        let (server, port) = try await Self.makeServer(
            profileResolver: store,
            anthropicUpstream: nativeGateway
        )
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

        let captures = await CaptureMockProtocol.waitForCaptureCount(30)
        #expect(captures.count == 30)
        let validHosts: Set<String> = ["native-gateway.example", "api.deepseek.com"]
        for capture in captures {
            #expect(validHosts.contains(capture.url.host ?? ""))
        }
    }

    // MARK: - T3 — sentinel parser + override routing

    @Test
    func sentinelParser() {
        // Happy path: id then path.
        let a = LLMProxyServer.parseSentinel(path: "/_oi/profile/buerai-pro/v1/messages")
        #expect(a.overrideId == "buerai-pro")
        #expect(a.requestPath == "/v1/messages")

        // No sentinel — pass through unchanged.
        let b = LLMProxyServer.parseSentinel(path: "/v1/messages")
        #expect(b.overrideId == nil)
        #expect(b.requestPath == "/v1/messages")

        // Sentinel with id but no further segments.
        let c = LLMProxyServer.parseSentinel(path: "/_oi/profile/buerai-pro")
        #expect(c.overrideId == "buerai-pro")
        #expect(c.requestPath == "/")

        // Empty id (literal `/_oi/profile//...`) is malformed —
        // treat as no sentinel rather than empty-string id, so the
        // proxy degrades to active default rather than throwing.
        let d = LLMProxyServer.parseSentinel(path: "/_oi/profile//v1/messages")
        #expect(d.overrideId == nil)
        #expect(d.requestPath == "/_oi/profile//v1/messages")

        // Path that just happens to start with similar prefix but
        // not the literal sentinel.
        let e = LLMProxyServer.parseSentinel(path: "/_oi/profilexxx/v1/messages")
        #expect(e.overrideId == nil)
        #expect(e.requestPath == "/_oi/profilexxx/v1/messages")

        // Healthz-prefixed sentinel: still parses out the id +
        // remaining /healthz path, so the healthz check downstream
        // sees /healthz on `requestPath` and short-circuits to 200.
        let f = LLMProxyServer.parseSentinel(path: "/_oi/profile/anything/healthz")
        #expect(f.overrideId == "anything")
        #expect(f.requestPath == "/healthz")
    }

    @Test
    func sentinelOverrideRoutesToOverrideProfileBaseURL() async throws {
        // T3 (a): a request whose URL carries the sentinel
        // `/_oi/profile/deepseek-v4-pro/...` while the GUI active
        // is the default (anthropic-native) — must forward to the
        // OVERRIDE profile's baseURL (api.deepseek.com), not to
        // anthropic.com.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        // Default active = anthropic-native (no setActiveProfile call).
        let nativeGateway = URL(string: "https://native-gateway.example")!
        let observer = ContextCapturingObserver()
        let (server, port) = try await Self.makeServer(
            profileResolver: store,
            anthropicUpstream: nativeGateway
        )
        server.setObserver(observer)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequestWithOverride(
            port: port,
            overrideId: BuiltinProfiles.deepseekV4Pro.id
        )

        let captures = await CaptureMockProtocol.waitForCaptureCount(1)
        #expect(captures.count == 1)
        // Forwarded URL host comes from the OVERRIDE profile, NOT
        // active (which would have routed to native-gateway.example).
        #expect(captures.first?.url.host == "api.deepseek.com",
                "override should win — got \(captures.first?.url.host ?? "nil")")
        // And the upstream sees the cleaned path — sentinel stripped.
        #expect(captures.first?.url.path == "/anthropic/v1/messages",
                "upstream must NOT see /_oi/profile prefix; got \(captures.first?.url.path ?? "nil")")

        // Context attribution reflects the override.
        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshots = await observer.snapshots()
        #expect(snapshots.first?.resolvedProfileId == BuiltinProfiles.deepseekV4Pro.id)
        #expect(snapshots.first?.profileSelectionSource == .perRequestOverride)
    }

    @Test
    func sentinelAbsentFallsBackToActiveDefault() async throws {
        // T3 (b): no sentinel → behavior is identical to pre-T3
        // (already covered by routingFollowsActiveProfileBaseURL but
        // re-asserted here with the source-attribution check the new
        // observer surfaces).
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)
        let observer = ContextCapturingObserver()
        let (server, port) = try await Self.makeServer(profileResolver: store)
        server.setObserver(observer)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequest(port: port)
        let captures = await CaptureMockProtocol.waitForCaptureCount(1)
        #expect(captures.first?.url.host == "api.deepseek.com")

        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshots = await observer.snapshots()
        #expect(snapshots.first?.resolvedProfileId == BuiltinProfiles.deepseekV4Pro.id)
        #expect(snapshots.first?.profileSelectionSource == .activeDefault)
    }

    @Test
    func unknownOverrideIdReturns400WithAvailableList() async throws {
        // T4 — sentinel carries a profile id that's not registered.
        // Proxy must respond 400 with a structured error body
        // listing the available ids; upstream must NOT be contacted.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        let (server, port) = try await Self.makeServer(profileResolver: store)
        let upstreamReached = UnknownOverrideUpstreamFlag()
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        // Use a custom mock responder that flags whether upstream was
        // ever asked to handle anything. The proxy's 400 short-circuit
        // must fire BEFORE forwarding, so this flag should stay false.
        // (CaptureMockProtocol's default behavior already records
        // captures — checking captures.isEmpty would also work, but a
        // dedicated flag is loud.)
        let url = URL(string: "http://127.0.0.1:\(port)/_oi/profile/totally-bogus-id/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","max_tokens":1,"messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 400, "expected 400, got \(http?.statusCode ?? -1)")

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        #expect(bodyString.contains("unknown_open_island_profile"))
        #expect(bodyString.contains("totally-bogus-id"))
        #expect(bodyString.contains("available"))
        // Verify body is parseable JSON with the expected envelope.
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errorObj = json?["error"] as? [String: Any]
        #expect(errorObj?["type"] as? String == "unknown_open_island_profile")
        #expect(errorObj?["id"] as? String == "totally-bogus-id")
        let available = errorObj?["available"] as? [String]
        #expect(available?.contains(BuiltinProfiles.anthropicNative.id) == true)
        #expect(available?.contains(BuiltinProfiles.deepseekV4Pro.id) == true)
        // Available is sorted alphabetically — verify so client
        // formatters can rely on stable order.
        #expect(available == available?.sorted())

        // Upstream was not contacted — captures stay empty because
        // the 400 fires before forward(). Wait briefly to give any
        // accidental request a chance to land before asserting.
        try await Task.sleep(nanoseconds: 100_000_000)
        let captures = CaptureMockProtocol.currentCaptures()
        #expect(captures.isEmpty, "upstream must not be contacted on 400 — got \(captures.count) captures")
        _ = upstreamReached  // silence unused
    }

    @Test
    func sentinelWinsWhenActiveAndOverrideDisagree() async throws {
        // T3 (c): the GUI active is one thing, the request carries
        // a sentinel pointing at a different profile — the SENTINEL
        // wins. This is the load-bearing invariant for multi-
        // terminal parallel use: terminal A has BuerAI active in the
        // GUI, terminal B can scriptwise invoke deepseek by setting
        // OI_PROFILE without disrupting A.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        // Active = anthropic-native. Default upstream = api.anthropic.com.
        // Override = deepseek-v4-pro. Expected forward host: deepseek.
        let observer = ContextCapturingObserver()
        let (server, port) = try await Self.makeServer(
            profileResolver: store,
            anthropicUpstream: URL(string: "https://native-gateway.example")!
        )
        server.setObserver(observer)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        try await Self.sendAnthropicRequestWithOverride(
            port: port,
            overrideId: BuiltinProfiles.deepseekV4Pro.id
        )
        let captures = await CaptureMockProtocol.waitForCaptureCount(1)
        #expect(captures.first?.url.host == "api.deepseek.com",
                "sentinel must win over active — host should be deepseek, got \(captures.first?.url.host ?? "nil")")

        // And the active profile in the store is unchanged.
        #expect(store.currentActiveProfile().id == BuiltinProfiles.anthropicNative.id)
    }

    @Test
    func resolvedProfileIdReflectsActiveAtRequestEntry() async throws {
        // T2 invariant: profile resolution happens once, at
        // `handleParsedRequest` entry, and is stored in
        // `LLMProxyRequestContext.resolvedProfileId`. A subsequent
        // active-profile flip must NOT retroactively change a
        // request that already entered. The next request, however,
        // must observe the new active.
        //
        // This proves the per-request resolution invariant without
        // racing on intra-request timing — we control the ordering
        // by completing one request before flipping for the next.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let store = Self.makeStore(suiteName: suiteName)
        // Default state is anthropic-native — leave it.
        let nativeGateway = URL(string: "https://native-gateway.example")!
        let observer = ContextCapturingObserver()
        let (server, port) = try await Self.makeServer(
            profileResolver: store,
            anthropicUpstream: nativeGateway
        )
        server.setObserver(observer)
        defer {
            server.stop()
            CaptureMockProtocol.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        // Request A — active = anthropic-native at entry.
        try await Self.sendAnthropicRequest(port: port)
        // Flip active. Anything entering AFTER this point sees the
        // new value; anything that already entered must not be
        // retroactively re-resolved.
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)
        // Request B — active = deepseek at entry.
        try await Self.sendAnthropicRequest(port: port)

        // Allow the proxy's `Task { observer.proxyWillForward(ctx) }`
        // to land on the actor before we read.
        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshots = await observer.snapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].resolvedProfileId == BuiltinProfiles.anthropicNative.id,
                "Request A should have entry-time profile id anthropic-native, got \(snapshots[0].resolvedProfileId ?? "nil")")
        #expect(snapshots[0].profileSelectionSource == .activeDefault)
        #expect(snapshots[1].resolvedProfileId == BuiltinProfiles.deepseekV4Pro.id,
                "Request B should have entry-time profile id deepseek-v4-pro, got \(snapshots[1].resolvedProfileId ?? "nil")")
        #expect(snapshots[1].profileSelectionSource == .activeDefault)
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

/// Single-bit flag used by T4's unknown-override test to assert
/// upstream was NEVER contacted. Plain class with a lock so reads
/// from the test task and writes from any URLProtocol
/// implementation can not race.
final class UnknownOverrideUpstreamFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    func set() { lock.lock(); reached = true; lock.unlock() }
    var didReach: Bool { lock.lock(); defer { lock.unlock() }; return reached }
}

/// Captures every `proxyWillForward` context for assertion in T2's
/// `resolvedProfileIdReflectsActiveAtRequestEntry`. The proxy fires
/// `proxyWillForward` on a detached `Task`, and the test reads from
/// its own task — so the captured array is touched from multiple
/// concurrency contexts. Swift 6 strict concurrency forbids
/// NSLock-unlock on an async path, so the lock interaction is wrapped
/// in synchronous helpers and the async overrides only call the
/// helpers.
final class ContextCapturingObserver: LLMProxyObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [LLMProxyRequestContext] = []

    private func append(_ context: LLMProxyRequestContext) {
        lock.lock(); defer { lock.unlock() }
        captured.append(context)
    }

    private func read() -> [LLMProxyRequestContext] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func snapshots() async -> [LLMProxyRequestContext] { read() }

    func proxyWillForward(_ context: LLMProxyRequestContext) async {
        append(context)
    }
    func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseStatus status: Int,
        headers: [String: String]
    ) async {}
    func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseChunk chunk: Data
    ) async {}
    func proxy(
        _ context: LLMProxyRequestContext,
        didCompleteWithError error: (any Error)?
    ) async {}
}
