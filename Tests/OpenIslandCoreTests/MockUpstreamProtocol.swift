import Foundation

/// `URLProtocol` subclass for integration-testing `LLMProxyServer`.
///
/// Tests inject this class into the server's `URLSessionConfiguration`
/// via `LLMProxyServer(additionalProtocolClasses: [MockUpstreamProtocol.self])`,
/// so every outbound request the proxy makes upstream — what would
/// normally hit `api.anthropic.com` / `api.openai.com` — is intercepted
/// and answered by an in-process `Responder` closure instead.
///
/// Concurrency: `Self.responder` is process-global state. Tests that
/// mutate it must run serially — see `LLMProxyServerIntegrationTests`'
/// `@Suite(.serialized)` trait.
final class MockUpstreamProtocol: URLProtocol {
    struct Response: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        /// Each `Data` is one delivery to `client.urlProtocol(_:didLoad:)`.
        /// Mocking SSE: pass one chunk per event so the proxy sees a
        /// realistic stream.
        var bodyChunks: [Data] = []
        /// Optional inter-chunk delay in seconds. Default 0 (deliver
        /// all chunks synchronously inside `startLoading`).
        var chunkDelay: TimeInterval = 0
        /// Optional terminal error (e.g. simulated network drop).
        /// Mutually exclusive with body chunks: if set, no
        /// `urlProtocolDidFinishLoading` is invoked.
        var terminalError: NSError?
    }

    typealias Responder = @Sendable (URLRequest) -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responder: Responder?

    static func setResponder(_ r: Responder?) {
        lock.lock(); defer { lock.unlock() }
        _responder = r
    }

    static func currentResponder() -> Responder? {
        lock.lock(); defer { lock.unlock() }
        return _responder
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        currentResponder() != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let responder = Self.currentResponder() else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockUpstreamProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "no responder set"]
                )
            )
            return
        }
        let response = responder(request)

        guard let httpResp = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockUpstreamProtocol",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "synthesized response invalid"]
                )
            )
            return
        }
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)

        if response.chunkDelay <= 0 {
            for chunk in response.bodyChunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else {
            // Deliver chunks on a background queue with the requested
            // delay so the proxy sees a real time-spread stream
            // (mimics SSE keep-alive + token cadence).
            let chunks = response.bodyChunks
            let delay = response.chunkDelay
            let client = self.client
            let proto = self
            DispatchQueue.global(qos: .userInitiated).async {
                for chunk in chunks {
                    Thread.sleep(forTimeInterval: delay)
                    client?.urlProtocol(proto, didLoad: chunk)
                }
                if let err = response.terminalError {
                    client?.urlProtocol(proto, didFailWithError: err)
                } else {
                    client?.urlProtocolDidFinishLoading(proto)
                }
            }
            return
        }

        if let err = response.terminalError {
            client?.urlProtocol(self, didFailWithError: err)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        // Cooperative cancel: nothing to stop in the synchronous path,
        // and the async path's chunks check the client weak-ref every
        // iteration so we naturally drop the trailing chunks here.
    }
}
