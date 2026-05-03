import Foundation
import Testing
@testable import OpenIslandCore

/// Offline end-to-end round-trip for the DeepSeek routing path. With
/// 4.6.1 (URL routing follows active profile) + 4.6.2 (body model
/// rewrite) landed, a claude CLI request that arrives at the proxy
/// while `active = deepseek-v4-pro` must come out the other side
/// with:
///
/// 1. Outbound URL pointed at `api.deepseek.com/anthropic` (NOT
///    `api.anthropic.com`)
/// 2. `Authorization: Bearer <stored DeepSeek key>` (NOT the user's
///    Anthropic key)
/// 3. Request body's `model` field rewritten to `deepseek-v4-pro`
///    (NOT `claude-opus-4-7[1m]`)
///
/// Phase 4 closeout earlier verified Anthropic→Anthropic only, which
/// is why the DeepSeek path's two end-to-end gaps stayed hidden until
/// a real user switched profiles. This test pins the round-trip so a
/// future regression on either gap fails CI loudly.
@Suite(.serialized)
struct LLMProxyDeepSeekRoundTripTests {
    /// File-private capture protocol — same shape as 4.6.1's
    /// `CaptureMockProtocol` but separate so the two suites don't
    /// race on a process-global responder. (Cross-suite serialization
    /// isn't available in swift-testing.)
    private final class Capture: URLProtocol, @unchecked Sendable {
        struct Request: Sendable {
            let url: URL
            let method: String
            let headers: [String: String]
            let body: Data
        }
        nonisolated(unsafe) static let lock = NSLock()
        nonisolated(unsafe) static var captured: [Request] = []
        nonisolated(unsafe) static var enabled: Bool = false
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
        static func append(_ r: Request) {
            lock.lock(); defer { lock.unlock() }
            captured.append(r)
        }
        static func current() -> [Request] {
            lock.lock(); defer { lock.unlock() }
            return captured
        }

        override class func canInit(with request: URLRequest) -> Bool { isEnabled() }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // URLSession's URLProtocol layer can deliver the body
            // either as `httpBody` (small bodies) or `httpBodyStream`
            // (anything URLSession decides to stream). Drain whichever
            // is present so the test sees the actual outbound bytes.
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                let bufSize = 64 * 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufSize)
                    if read <= 0 { break }
                    body.append(buffer, count: read)
                }
            }
            var headers: [String: String] = [:]
            for (k, v) in (request.allHTTPHeaderFields ?? [:]) {
                headers[k] = v
            }
            Self.append(Request(
                url: request.url ?? URL(string: "missing:")!,
                method: request.httpMethod ?? "?",
                headers: headers,
                body: body
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

    /// In-memory credentials backend for the test — avoids hitting
    /// the real Keychain. Implementation symmetry with
    /// `RouterCredentialsStoreTests`'s `InMemoryRouterCredentialsBackend`.
    private final class InMemoryCreds: RouterCredentialsBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        func setCredential(_ value: String, for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            storage[account] = value
        }
        func credential(for account: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[account]
        }
        func deleteCredential(for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: account)
        }
        func listAccounts() throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(storage.keys)
        }
    }

    @Test
    func deepSeekRoundTripRewritesURLAuthAndModel() async throws {
        // 1. Set up: DeepSeek profile active in the store, DeepSeek
        // key stashed in the credentials backend.
        let suiteName = "OpenIsland.LLMProxy.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = UpstreamProfileStore(userDefaults: defaults)
        try store.setActiveProfile(BuiltinProfiles.deepseekV4Pro.id)

        let creds = RouterCredentialsStore(backend: InMemoryCreds())
        let storedKey = "sk-roundtrip-\(UUID().uuidString.prefix(16))"
        try creds.setCredential(storedKey, for: "deepseek")

        Self.Capture.enable()
        let server = LLMProxyServer(
            configuration: LLMProxyConfiguration(
                port: 0,
                anthropicUpstream: URL(string: "https://api.anthropic.com")!,
                openAIUpstream: URL(string: "https://api.openai.com")!
            ),
            additionalProtocolClasses: [Self.Capture.self],
            credentialsStore: creds,
            profileResolver: store
        )
        try server.start()
        try await server.waitUntilReady(timeout: 3)
        guard let port = server.actualPort else {
            throw NSError(domain: "test", code: -1)
        }
        defer {
            server.stop()
            Self.Capture.disable()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        // 2. Send a claude-CLI-shaped request: Anthropic model id +
        // user's Anthropic Bearer key (which the rewriter must
        // overwrite).
        var clientReq = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!
        )
        clientReq.httpMethod = "POST"
        clientReq.setValue("Bearer ANTHROPIC-KEY-FROM-CLIENT", forHTTPHeaderField: "Authorization")
        clientReq.setValue("application/json", forHTTPHeaderField: "content-type")
        clientReq.httpBody = Data(#"""
            {
              "model": "claude-opus-4-7[1m]",
              "max_tokens": 4096,
              "messages": [{"role":"user","content":"hi"}]
            }
            """#.utf8)

        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(for: clientReq)

        // 3. Inspect what the proxy actually forwarded.
        let captures = Self.Capture.current()
        #expect(captures.count == 1)
        guard let outbound = captures.first else { return }

        // (a) URL = api.deepseek.com/anthropic + path appended.
        #expect(outbound.url.host == "api.deepseek.com")
        #expect(outbound.url.path == "/anthropic/v1/messages")

        // (b) Authorization rewritten to Bearer <stored DeepSeek
        // key>. URLRequest.allHTTPHeaderFields canonicalizes header
        // names — look up case-insensitively to be safe.
        let authValue = outbound.headers.first(
            where: { $0.key.lowercased() == "authorization" }
        )?.value
        #expect(authValue == "Bearer \(storedKey)")
        #expect(authValue?.contains("ANTHROPIC-KEY-FROM-CLIENT") == false)

        // (c) Body's model field replaced wholesale.
        guard let bodyJSON = try? JSONSerialization.jsonObject(with: outbound.body) as? [String: Any] else {
            Issue.record("outbound body did not parse as JSON")
            return
        }
        #expect(bodyJSON["model"] as? String == "deepseek-v4-pro")
        // Other body fields preserved.
        #expect(bodyJSON["max_tokens"] as? Int == 4096)
        let messages = bodyJSON["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "user")
    }
}
