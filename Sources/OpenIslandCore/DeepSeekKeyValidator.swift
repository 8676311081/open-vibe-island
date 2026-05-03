import Foundation

/// Validates a DeepSeek API key by issuing a tiny POST against
/// `api.deepseek.com/anthropic/v1/messages` with the key in the
/// Authorization header. The endpoint speaks Anthropic format, so
/// `model: deepseek-chat` + a 1-token "ping" message is enough to
/// distinguish a working key from a 401 / network failure.
///
/// **Why a real network probe and not just a regex on the key
/// shape:** DeepSeek keys don't follow a published format; the only
/// authoritative answer is "does the upstream accept it". A 401
/// here points the user straight at the misconfiguration, which is
/// the whole reason the routing pane offers a "Test connection"
/// button before saving the key to Keychain.
///
/// Endpoint URL and `URLSession` are injectable so tests can swap
/// in a `MockUpstreamProtocol`-backed session — the same pattern
/// existing `LLMProxyServer` integration tests use.
public struct DeepSeekKeyValidator: Sendable {
    public static let defaultEndpointURL = URL(
        string: "https://api.deepseek.com/anthropic/v1/messages"
    )!

    public enum Result: Sendable, Equatable {
        case valid
        /// HTTP 401 — the key reached upstream and was explicitly
        /// rejected. Distinct from `unexpectedStatus` because UI
        /// has a specific message for it ("Key was rejected; check
        /// you copied the full string").
        case invalidKey
        /// Any non-2xx, non-401 status. `body` is up to 200 chars of
        /// upstream response (truncated) so the routing pane can
        /// surface concrete diagnosis text instead of "failed".
        case unexpectedStatus(code: Int, body: String)
        /// Networking failure (DNS, TLS, timeout). Argument is
        /// `error.localizedDescription`.
        case networkError(message: String)
    }

    public let endpointURL: URL
    private let session: URLSession

    public init(
        endpointURL: URL = DeepSeekKeyValidator.defaultEndpointURL,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.session = session
    }

    /// Issues the probe request. Always returns — never throws — so
    /// UI code can pattern-match on `Result` without a try/catch.
    public func validate(key: String) async -> Result {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Anthropic protocol header. DeepSeek's /anthropic endpoint
        // mirrors the same versioning contract.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Minimal body. `max_tokens: 1` keeps cost ~zero; the user
        // pays for at most one output token even on success.
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "ping"],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError(message: "Non-HTTP response")
            }
            let snippet: () -> String = {
                let trimmed = data.prefix(200)
                return String(data: trimmed, encoding: .utf8) ?? "<binary>"
            }
            switch http.statusCode {
            case 200..<300:
                return .valid
            case 401:
                return .invalidKey
            default:
                return .unexpectedStatus(code: http.statusCode, body: snippet())
            }
        } catch {
            return .networkError(message: error.localizedDescription)
        }
    }
}
