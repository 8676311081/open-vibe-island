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
    public let baseURL: URL
    public let timeout: TimeInterval
    private let session: URLSession

    public init(
        baseURL: URL,
        timeout: TimeInterval = 10,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    // MARK: - Connection test

    /// POST a minimal Anthropic-format probe to `{baseURL}/v1/messages`.
    /// Uses `model` for the body's model field — if nil, defaults to
    /// `"ping"` (a sentinel that should trigger an upstream model-not-
    /// found error, still producible enough to test auth).
    public func validate(key: String, model: String? = nil) async -> Result {
        let probeModel = model ?? "ping"
        let endpoint = baseURL.appendingPathComponent("v1/messages")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: req, delegate: nil)
            guard let http = response as? HTTPURLResponse else {
                return .networkError(message: "No HTTP response")
            }
            return classify(http.statusCode, body: Data())
        } catch {
            return classifyNSError(error as NSError)
        }
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
        let endpoint = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")

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
            return nil
        }
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
