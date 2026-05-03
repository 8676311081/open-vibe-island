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
        /// rejected. Distinct path because UI must force the user
        /// to re-enter the key (Save button stays disabled).
        case invalidKey
        /// HTTP 429 — key is valid but the account is rate-limited
        /// right now. Save IS allowed (the key works, the user just
        /// needs to wait); UI surfaces an amber notice rather than
        /// a hard error.
        case rateLimited
        /// Any 5xx upstream response. `body` is up to 200 chars of
        /// upstream response (truncated). Save IS allowed because
        /// the upstream is at fault, not the key — saving lets the
        /// user retry without re-typing the secret.
        case upstreamError(code: Int, body: String)
        /// Connection timed out (URLError.timedOut). Save allowed
        /// for the same reason as upstreamError — transient network
        /// state shouldn't force key re-entry.
        case timeout
        /// Networking failure that's neither timeout nor an HTTP
        /// response (DNS failure, TLS handshake error, etc.).
        case networkError(message: String)
    }

    public let endpointURL: URL
    public let timeout: TimeInterval
    private let session: URLSession

    public init(
        endpointURL: URL = DeepSeekKeyValidator.defaultEndpointURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 10
    ) {
        self.endpointURL = endpointURL
        self.timeout = timeout
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
        // Per-request timeout for the probe. Short by design: the
        // routing pane shouldn't make the user wait the URLSession
        // default (60 s) when the upstream is unreachable.
        request.timeoutInterval = timeout

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
            case 429:
                return .rateLimited
            case 500..<600:
                return .upstreamError(code: http.statusCode, body: snippet())
            default:
                // Treat unfamiliar 4xx (other than 401/429) as
                // upstream-error too — we have no UI category for
                // them and this matches the "save is OK" semantics
                // (the *key* isn't the problem).
                return .upstreamError(code: http.statusCode, body: snippet())
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            return .timeout
        } catch {
            return .networkError(message: error.localizedDescription)
        }
    }

    /// Save-button gate used by the key-config sheet. `nil` (no test
    /// run yet) and `.invalidKey` block save; everything else allows
    /// it. `.rateLimited` / `.upstreamError` / `.timeout` are
    /// transient upstream conditions where the key itself is fine —
    /// forcing the user to re-type the secret in those cases is
    /// hostile UX.
    public static func saveAllowed(for result: Result?) -> Bool {
        guard let result else { return false }
        switch result {
        case .valid, .rateLimited, .upstreamError, .timeout:
            return true
        case .invalidKey, .networkError:
            return false
        }
    }
}
