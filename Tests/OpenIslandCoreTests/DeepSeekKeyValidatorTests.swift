import Foundation
import Testing
@testable import OpenIslandCore

/// File-private URLProtocol mock. Deliberately separate from
/// `MockUpstreamProtocol` (used by `LLMProxyServerIntegrationTests`):
/// `MockUpstreamProtocol` shares a global responder with other test
/// files — concurrent suites racing on it caused the original
/// failure. Keeping this class `private` to this file means only
/// `DeepSeekKeyValidatorTests` registers responders on it, so the
/// only contention is within-suite, which `@Suite(.serialized)`
/// handles.
private final class LocalDeepSeekMockProtocol: URLProtocol {
    struct Response: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var bodyData: Data = Data()
        var terminalError: NSError?
    }

    typealias Responder = @Sendable (URLRequest) -> Response

    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: Responder?

    static func setResponder(_ r: Responder?) {
        lock.lock(); defer { lock.unlock() }
        responder = r
    }

    private static func currentResponder() -> Responder? {
        lock.lock(); defer { lock.unlock() }
        return responder
    }

    override class func canInit(with request: URLRequest) -> Bool {
        currentResponder() != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let r = Self.currentResponder() else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "LocalDeepSeekMockProtocol", code: -1)
            )
            return
        }
        let response = r(request)
        if let terminal = response.terminalError {
            client?.urlProtocol(self, didFailWithError: terminal)
            return
        }
        guard let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "LocalDeepSeekMockProtocol", code: -2)
            )
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.bodyData.isEmpty {
            client?.urlProtocol(self, didLoad: response.bodyData)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `@Suite(.serialized)` — within-suite tests share the global
/// responder so they MUST run sequentially. Cross-suite is fine
/// because `LocalDeepSeekMockProtocol` is file-private (no other
/// suite can use it).
@Suite(.serialized)
struct DeepSeekKeyValidatorTests {
    /// Build a validator pointing at a sentinel URL with the file-
    /// private mock URLProtocol injected. Tests set the responder
    /// before calling `validate(key:)` and clear it via defer.
    private static func makeValidator(timeout: TimeInterval = 10) -> DeepSeekKeyValidator {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LocalDeepSeekMockProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        return DeepSeekKeyValidator(
            endpointURL: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
            session: session,
            timeout: timeout
        )
    }
    private static func makeValidatorAndSession(
        timeout: TimeInterval = 10,
        responder: @escaping LocalDeepSeekMockProtocol.Responder
    ) -> (DeepSeekKeyValidator, URLSession) {
        // Kept for signature compatibility with the per-test
        // closures below; session is unused now (responder is global)
        // but the API shape avoids re-shaping each test.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LocalDeepSeekMockProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        LocalDeepSeekMockProtocol.setResponder(responder)
        let validator = DeepSeekKeyValidator(
            endpointURL: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
            session: session,
            timeout: timeout
        )
        return (validator, session)
    }

    @Test
    func connectionTesterSuccessReturnsValid() async {
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                bodyData: Data(#"{"id":"msg_x","content":[]}"#.utf8)
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        #expect(await validator.validate(key: "sk-test") == .valid)
    }

    @Test
    func connectionTesterReturnsInvalidKeyOn401() async {
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                statusCode: 401,
                bodyData: Data(#"{"error":"invalid api key"}"#.utf8)
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        #expect(await validator.validate(key: "sk-bogus") == .invalidKey)
    }

    @Test
    func connectionTesterReturnsRateLimitedOn429() async {
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                statusCode: 429,
                bodyData: Data(#"{"error":"rate limit exceeded"}"#.utf8)
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        #expect(await validator.validate(key: "sk-real") == .rateLimited)
    }

    @Test
    func connectionTesterReturnsUpstreamErrorOn5xx() async {
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                statusCode: 503,
                bodyData: Data("upstream busy".utf8)
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        let result = await validator.validate(key: "sk-real")
        guard case let .upstreamError(code, body) = result else {
            Issue.record("expected .upstreamError, got \(result)")
            return
        }
        #expect(code == 503)
        #expect(body.contains("upstream busy"))
    }

    @Test
    func connectionTesterReturnsTimeoutOnTimedOutError() async {
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                terminalError: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: nil
                )
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        #expect(await validator.validate(key: "sk-real") == .timeout)
    }

    @Test
    func connectionTesterReturnsNetworkErrorOnGenericFailure() async {
        // Anything that isn't a timeout should land in the generic
        // networkError bucket — DNS, TLS, connection-reset etc.
        let (validator, session) = Self.makeValidatorAndSession { _ in
            LocalDeepSeekMockProtocol.Response(
                terminalError: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCannotFindHost,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot find host"]
                )
            )
        }
        defer { LocalDeepSeekMockProtocol.setResponder(nil); _ = session }
        guard case let .networkError(message) = await validator.validate(key: "sk-real") else {
            Issue.record("expected .networkError")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: - saveAllowed gate

    @Test
    func saveAllowedTrueForValidRateLimitedTimeoutAndUpstreamError() {
        // Key reached upstream and either succeeded or had a
        // transient upstream-side issue — saving the key is OK.
        #expect(DeepSeekKeyValidator.saveAllowed(for: .valid))
        #expect(DeepSeekKeyValidator.saveAllowed(for: .rateLimited))
        #expect(DeepSeekKeyValidator.saveAllowed(for: .timeout))
        #expect(DeepSeekKeyValidator.saveAllowed(for: .upstreamError(code: 503, body: "x")))
    }

    @Test
    func saveAllowedFalseForInvalidKeyAndNetworkError() {
        // .invalidKey: the upstream told us the key is bad; force
        // re-entry. .networkError: we never reached upstream, so
        // we don't actually know whether the key works — block
        // until a real test succeeds.
        #expect(!DeepSeekKeyValidator.saveAllowed(for: .invalidKey))
        #expect(!DeepSeekKeyValidator.saveAllowed(for: .networkError(message: "DNS failed")))
    }

    @Test
    func saveAllowedFalseForNilResult() {
        // Sheet just opened; user hasn't tested yet. Save must be
        // disabled until they press Test Connection.
        #expect(!DeepSeekKeyValidator.saveAllowed(for: nil))
    }
}
