import Foundation
import Network
import Testing
@testable import OpenIslandCore

/// End-to-end tests for `LLMProxyServer`: real NWListener + real
/// URLSession-based outbound, with `MockUpstreamProtocol` standing
/// in for `api.anthropic.com` / `api.openai.com`.
///
/// Tests are serialized — `MockUpstreamProtocol.responder` is process-
/// global state, so two suites running in parallel would race on it.
@Suite(.serialized)
struct LLMProxyServerIntegrationTests {
    // MARK: - Fixtures

    private static func makeTempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llm-stats-\(UUID().uuidString).json")
    }

    /// Build a fresh server bound to a kernel-assigned port + an
    /// observer wired into a fresh on-disk stats store. Returns
    /// (server, store, port). Caller is responsible for `server.stop()`
    /// and removing the store URL.
    private static func makeServer(
        anthropicMock: URL = URL(string: "https://api.anthropic.com")!,
        openAIMock: URL = URL(string: "https://api.openai.com")!
    ) async throws -> (LLMProxyServer, LLMStatsStore, UInt16, URL) {
        let storeURL = makeTempStoreURL()
        let store = LLMStatsStore(url: storeURL)
        let server = LLMProxyServer(
            configuration: LLMProxyConfiguration(
                port: 0,
                anthropicUpstream: anthropicMock,
                openAIUpstream: openAIMock
            ),
            additionalProtocolClasses: [MockUpstreamProtocol.self]
        )
        let observer = LLMUsageObserver(store: store)
        server.setObserver(observer)
        try server.start()
        try await server.waitUntilReady(timeout: 3)
        guard let port = server.actualPort else {
            throw NSError(domain: "test", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no port"])
        }
        return (server, store, port, storeURL)
    }

    private static func makeClientSession() -> URLSession {
        // The client side is a plain URLSession — only the server-
        // side outbound path needs `MockUpstreamProtocol` injected.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }

    private static func proxyURL(port: UInt16, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Wait until the observer's in-flight scratchpad has drained back
    /// into the store, i.e. the request is fully recorded. The proxy's
    /// hot path is fire-and-forget into the actor, so a short poll
    /// loop on the snapshot is the cheapest sync barrier.
    private static func awaitStatsRecorded(
        in store: LLMStatsStore,
        timeout: TimeInterval = 3
    ) async throws -> LLMStatsSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = await store.currentSnapshot()
            if !snap.days.isEmpty { return snap }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        return await store.currentSnapshot()
    }

    /// Cleanup that survives a thrown test. Caller passes the store
    /// URL because `LLMStatsStore` is an actor and its `url` property
    /// can't be accessed synchronously from a nonisolated `defer`.
    private static func teardown(_ server: LLMProxyServer, _ storeURL: URL) {
        server.stop()
        try? FileManager.default.removeItem(at: storeURL)
        MockUpstreamProtocol.setResponder(nil)
    }

    // MARK: - (a) Anthropic SSE → tokens land in stats

    @Test
    func anthropicSSEStreamPushesTokensIntoStore() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Three SSE events: message_start (initial usage), one
        // content delta, message_delta (output cumulative). The
        // trailing `\n` is critical — SSE event termination is
        // double-LF and Swift's `"""` literal only emits a single
        // trailing newline before the closing delimiter.
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m_1","model":"claude-opus-4-7","usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

        event: message_delta
        data: {"type":"message_delta","delta":{},"usage":{"output_tokens":42}}

        """ + "\n"
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-cli/2.1.123", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        // Body bytes pass through identity-decoded (no proxy
        // re-encoding).
        #expect(String(data: data, encoding: .utf8)?.contains("message_start") == true)

        // Stats land. Anthropic input = input + cacheCreate + cacheRead.
        let snap = try await Self.awaitStatsRecorded(in: store)
        let day = LLMStatsStore.dayKey(for: Date())
        let bucket = try #require(snap.days[day]?[LLMClient.claudeCode.rawValue])
        #expect(bucket.tokensIn == 150)        // 100 + 50 + 0
        #expect(bucket.tokensOut == 42)
        #expect(bucket.inputTokens == 100)
        #expect(bucket.cacheReadTokens == 50)
        #expect(bucket.cacheCreationTokens == 0)
        #expect(bucket.turns == 1)
    }

    // MARK: - (b) /v1/chat/completions: stream_options.include_usage injected

    @Test
    func openAIChatCompletionsHasStreamOptionsIncludeUsageInjected() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Capture the body the proxy hands to the upstream so we can
        // inspect the rewriter's effect.
        let captured = CapturedBody()
        MockUpstreamProtocol.setResponder { request in
            captured.set(request.httpBody ?? request.httpBodyStream.flatMap { Self.drainStream($0) } ?? Data())
            // Minimal SSE done-event so the path completes cleanly.
            let body = "data: [DONE]\n\n"
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }

        let inboundBody = #"{"model":"gpt-4o","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(inboundBody.utf8)

        _ = try await Self.makeClientSession().data(for: req)

        let outbound = try #require(String(data: captured.value, encoding: .utf8))
        // Rewriter contract: stream_options.include_usage = true is
        // present; original `stream:true` survives.
        #expect(outbound.contains("\"include_usage\""))
        #expect(outbound.contains("true"))
        #expect(outbound.contains("\"stream\":true") || outbound.contains("\"stream\" : true"))
    }

    // MARK: - (c) Upstream 502 → transparent error

    @Test
    func upstream502PassesThroughVerbatim() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let upstreamBody = #"{"error":"upstream is on fire"}"#
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 502,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data(upstreamBody.utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 502)
        #expect(String(data: data, encoding: .utf8) == upstreamBody)
    }

    // MARK: - (d) Duplicate tool_use within 5-min window → dup warning

    @Test
    func duplicateToolUseWithinWindowFlagsDuplicateWarning() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Non-streaming response with one tool_use block. Send the
        // same response (same name, same input) twice — the second
        // hit must increment duplicateToolCalls.
        let toolUseBody = """
        {
          "id":"m_1",
          "model":"claude-opus-4-7",
          "stop_reason":"tool_use",
          "content":[{"type":"tool_use","id":"t_1","name":"Bash","input":{"cmd":"ls /tmp"}}],
          "usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}
        }
        """
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data(toolUseBody.utf8)]
            )
        }

        for _ in 0..<2 {
            var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("claude-cli/2.1.123", forHTTPHeaderField: "User-Agent")
            req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
            _ = try await Self.makeClientSession().data(for: req)
        }

        // Wait until both turns recorded.
        let deadline = Date().addingTimeInterval(3)
        var dupWarning = false
        while Date() < deadline {
            let snap = await store.currentSnapshot()
            let day = LLMStatsStore.dayKey(for: Date())
            if let bucket = snap.days[day]?[LLMClient.claudeCode.rawValue],
               bucket.duplicateToolCalls >= 1 {
                dupWarning = true
                break
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        #expect(dupWarning)
    }

    // MARK: - (e) Client cancel mid-stream → proxy survives

    @Test
    func clientCancelMidStreamLeavesProxyResponsive() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Slow chunked SSE — gives the client time to cancel mid-stream.
        MockUpstreamProtocol.setResponder { _ in
            let chunks = (0..<20).map { i in
                Data("event: ping\ndata: {\"i\":\(i)}\n\n".utf8)
            }
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: chunks,
                chunkDelay: 0.05  // 50 ms between events
            )
        }

        // 1) Start a request and cancel it mid-flight.
        let cancellingTask = Task<Void, Never> {
            var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
            _ = try? await Self.makeClientSession().data(for: req)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms in
        cancellingTask.cancel()
        try await Task.sleep(nanoseconds: 200_000_000) // settle

        // 2) Issue a fresh request — server must still accept and
        //    serve. (Implicitly proves the listener wasn't taken
        //    down by the cancelled connection.)
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m_2","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}

        event: message_delta
        data: {"type":"message_delta","delta":{},"usage":{"output_tokens":1}}

        """ + "\n"
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }
        var req2 = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
        let (_, resp2) = try await Self.makeClientSession().data(for: req2)
        let http2 = try #require(resp2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
    }

    // MARK: - (f) abc09c6 gap: outbound Accept-Encoding forced to identity

    @Test
    func outboundRequestForcesAcceptEncodingIdentity() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let captured = CapturedHeaders()
        MockUpstreamProtocol.setResponder { request in
            captured.set(request.allHTTPHeaderFields ?? [:])
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data("{}".utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Client hints gzip — proxy must override before sending
        // upstream so URLSession's auto-gunzip doesn't stomp on the
        // body before the agent sees it.
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        _ = try await Self.makeClientSession().data(for: req)

        let outbound = captured.value
        let acceptEnc = outbound["Accept-Encoding"] ?? outbound["accept-encoding"] ?? ""
        #expect(acceptEnc.lowercased() == "identity",
                "outbound Accept-Encoding was \(acceptEnc), expected identity")
    }

    // MARK: - Helpers

    private static func drainStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

// MARK: - Test-only thread-safe captures

/// Captures the request body the mock upstream saw, across test
/// thread boundaries. Plain `var` capture would race because the mock
/// runs on a URLProtocol-internal queue.
private final class CapturedBody: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ v: Data) { lock.lock(); data = v; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class CapturedHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    func set(_ v: [String: String]) { lock.lock(); headers = v; lock.unlock() }
    var value: [String: String] { lock.lock(); defer { lock.unlock() }; return headers }
}
