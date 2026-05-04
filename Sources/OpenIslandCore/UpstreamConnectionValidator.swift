import Foundation

/// Generic upstream connectivity tester. Generalizes the pattern from
/// `DeepSeekKeyValidator` — the endpoint URL is now configurable, and
/// model-list auto-discovery is added as `fetchModels(key:)`.
///
/// Use this for custom-profile creation: enter a base URL + API key,
/// test the connection with a probe POST, then fetch available models
/// from `GET /v1/models` (best-effort; returns nil if the endpoint
/// doesn't exist or returns a non-200 status).
public struct UpstreamConnectionValidator: Sendable {
    public typealias Result = DeepSeekKeyValidator.Result

    /// The upstream base URL (e.g. `https://api.deepseek.com/anthropic`).
    ///
    /// The value is canonicalized for Anthropic-format routing: users
    /// often paste an OpenAI-style base such as `https://host/v1` from
    /// provider docs, while Claude Code will later send `/v1/messages`
    /// through the proxy. Keeping `/v1` in `baseURL` would make the
    /// proxy forward to `/v1/v1/messages`. We therefore strip one
    /// trailing `/v1` segment for storage and endpoint construction.
    public let baseURL: URL
    public let timeout: TimeInterval
    private let session: URLSession
    private let maxAttempts: Int

    public init(
        baseURL: URL,
        timeout: TimeInterval = 10,
        maxAttempts: Int = 3,
        session: URLSession? = nil
    ) {
        self.baseURL = Self.canonicalAnthropicBaseURL(baseURL)
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    // MARK: - Connection test

    /// POST a minimal Anthropic-format probe to `{baseURL}/v1/messages`.
    /// Uses `model` for the body's model field — if nil, defaults to
    /// `"ping"` (a sentinel that should trigger an upstream model-not-
    /// found error, still producible enough to test auth).
    public func validate(key: String, model: String? = nil) async -> Result {
        let probeModel = model ?? "ping"
        let endpoint = endpointURL(for: "v1/messages")
        let body: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var lastError: NSError?
        for attempt in 1...maxAttempts {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = bodyData

            do {
                let (data, response) = try await session.data(for: req, delegate: nil)
                guard let http = response as? HTTPURLResponse else {
                    return .networkError(message: "No HTTP response")
                }
                return classify(http.statusCode, body: data)
            } catch {
                let ns = error as NSError
                lastError = ns
                if attempt < maxAttempts, Self.isRetryable(ns) {
                    await sleepBeforeRetry(attempt: attempt)
                    continue
                }
                return classifyNSError(ns)
            }
        }
        return classifyNSError(lastError ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
    }

    // MARK: - Model list

    /// Attempt to fetch the model list from `GET {baseURL}/v1/models`.
    /// Returns model id strings on 200, nil on any other status or
    /// network error (best-effort — the caller falls back to manual
    /// model entry).
    ///
    /// Parses the standard `{"data": [{"id": "model-name"}, ...]}`
    /// response used by both Anthropic and OpenAI-compatible APIs.
    public func fetchModels(key: String) async -> [String]? {
        let endpoint = endpointURL(for: "v1/models")
        for attempt in 1...maxAttempts {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            do {
                let (data, response) = try await session.data(for: req, delegate: nil)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]]
                else { return nil }
                let ids = models.compactMap { $0["id"] as? String }
                return ids.isEmpty ? nil : ids.sorted()
            } catch {
                let ns = error as NSError
                if attempt < maxAttempts, Self.isRetryable(ns) {
                    await sleepBeforeRetry(attempt: attempt)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    // MARK: - URL normalization / retry helpers

    /// Canonical base URL to persist in `UpstreamProfile.baseURL` for
    /// Anthropic-format proxying. Claude Code supplies `/v1/messages`
    /// as the request target, so a base ending in `/v1` would double
    /// the version segment at runtime.
    public static func canonicalAnthropicBaseURL(_ url: URL) -> URL {
        var absolute = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while absolute.hasSuffix("/") { absolute.removeLast() }
        guard var components = URLComponents(string: absolute) else { return url }
        let path = components.percentEncodedPath
        if path == "/v1" {
            components.percentEncodedPath = ""
        } else if path.hasSuffix("/v1") {
            components.percentEncodedPath = String(path.dropLast(3))
        }
        return components.url ?? url
    }

    private func endpointURL(for relativePath: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
        return URL(string: base + suffix) ?? baseURL.appendingPathComponent(relativePath)
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func sleepBeforeRetry(attempt: Int) async {
        let millis = UInt64(min(1_000, 200 * attempt))
        try? await Task.sleep(nanoseconds: millis * 1_000_000)
    }

    // MARK: - Internal classification

    private func classify(_ status: Int, body: Data) -> Result {
        switch status {
        case 200..<300: return .valid
        case 401: return .invalidKey
        case 429: return .rateLimited
        case 400..<500:
            let snippet = String(data: body.prefix(200), encoding: .utf8) ?? ""
            return .upstreamError(code: status, body: snippet)
        default:
            let snippet = String(data: body.prefix(200), encoding: .utf8) ?? ""
            return .upstreamError(code: status, body: snippet)
        }
    }

    private func classifyNSError(_ error: NSError) -> Result {
        guard error.domain == NSURLErrorDomain else {
            return .networkError(message: error.localizedDescription)
        }
        if error.code == NSURLErrorTimedOut {
            return .timeout
        }
        return .networkError(message: error.localizedDescription)
    }
}
