import Foundation
import Testing
@testable import OpenIslandCore

/// File-private mock URLProtocol for the validator tests.
private final class ValidatorMockProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "ValidatorMockProtocol", code: -1))
            return
        }
        let response = r(request)
        if let err = response.terminalError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let http = HTTPURLResponse(
            url: request.url!, statusCode: response.statusCode,
            httpVersion: "HTTP/1.1", headerFields: response.headers
        ) else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "ValidatorMockProtocol", code: -2))
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

@Suite(.serialized)
struct UpstreamConnectionValidatorTests {
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ValidatorMockProtocol.self] + (cfg.protocolClasses ?? [])
        return URLSession(configuration: cfg)
    }

    @Test
    func validatorSendsProbeToConfiguredURL() async {
        ValidatorMockProtocol.setResponder { req in
            #expect(req.url?.host == "api.example.com")
            #expect(req.url?.path == "/anthropic/v1/messages")
            return ValidatorMockProtocol.Response(statusCode: 200)
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.example.com/anthropic")!,
            session: Self.makeSession()
        )
        let result = await validator.validate(key: "sk-test-key")
        #expect(result == .valid)
    }

    @Test
    func validator401ReturnsInvalidKey() async {
        ValidatorMockProtocol.setResponder { _ in
            ValidatorMockProtocol.Response(statusCode: 401)
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.example.com")!,
            session: Self.makeSession()
        )
        let result = await validator.validate(key: "sk-bogus")
        #expect(result == .invalidKey)
    }

    @Test
    func validator429ReturnsRateLimited() async {
        ValidatorMockProtocol.setResponder { _ in
            ValidatorMockProtocol.Response(statusCode: 429)
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.example.com")!,
            session: Self.makeSession()
        )
        let result = await validator.validate(key: "sk-real")
        #expect(result == .rateLimited)
    }

    @Test
    func fetchModelsReturnsParsedList() async {
        let modelsJSON = Data(#"""
            {"data": [
                {"id": "claude-sonnet-4-5", "created": 123},
                {"id": "claude-haiku-4-5"},
                {"id": "claude-opus-4-7"}
            ]}
            """#.utf8)
        ValidatorMockProtocol.setResponder { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.path == "/v1/models")
            return ValidatorMockProtocol.Response(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                bodyData: modelsJSON
            )
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.anthropic.com")!,
            session: Self.makeSession()
        )
        let models = await validator.fetchModels(key: "sk-test")
        #expect(models == ["claude-haiku-4-5", "claude-opus-4-7", "claude-sonnet-4-5"])
    }

    @Test
    func fetchModelsNilOn404() async {
        ValidatorMockProtocol.setResponder { _ in
            ValidatorMockProtocol.Response(statusCode: 404)
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.example.com")!,
            session: Self.makeSession()
        )
        let models = await validator.fetchModels(key: "sk-test")
        #expect(models == nil)
    }

    @Test
    func validateUsesCustomModelInProbe() async {
        ValidatorMockProtocol.setResponder { req in
            let body = req.httpBody ?? Data()
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["model"] as? String == "my-custom-model")
            }
            return ValidatorMockProtocol.Response(statusCode: 200)
        }
        defer { ValidatorMockProtocol.setResponder(nil) }

        let validator = UpstreamConnectionValidator(
            baseURL: URL(string: "https://api.example.com")!,
            session: Self.makeSession()
        )
        _ = await validator.validate(key: "sk-test", model: "my-custom-model")
    }
}
