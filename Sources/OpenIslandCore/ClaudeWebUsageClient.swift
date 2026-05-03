import Foundation

/// Talks to claude.ai's organization-usage endpoint to fetch realtime
/// account-level rate-limit utilization (Max plan 5h / 7d windows etc.).
///
/// This is the data source surfaced in Claude Desktop's Settings → Usage
/// page. We use the same web API the Anthropic Web UI uses, authenticated
/// via the user's own session cookie. Schema discovery was done by
/// driving Chrome via the Claude in Chrome MCP and capturing the
/// `/api/organizations/{id}/usage` response — see
/// docs/usage-freshness-investigation.md for the full investigation.
///
/// Two endpoints are exposed:
/// - `fetchOrganizations` — list of orgs the cookie is signed into; we use
///   it to resolve `org_id` automatically so users don't have to paste a
///   UUID by hand (per DeepSeek review).
/// - `fetchUsageRaw` — returns the response body verbatim. Callers are
///   expected to drop it directly onto the statusline cache file
///   (`/tmp/open-island-rl.json`); ClaudeUsageLoader already accepts the
///   `utilization` field as a fallback for `used_percentage`, so no schema
///   translation is needed.
public protocol ClaudeWebUsageFetching: Sendable {
    func fetchOrganizations(cookie: String) async throws -> [ClaudeWebOrganization]
    func fetchUsageRaw(cookie: String, organizationID: String) async throws -> Data
}

public struct ClaudeWebOrganization: Equatable, Sendable {
    public let id: String
    public let role: String?
    public let name: String?

    public init(id: String, role: String?, name: String?) {
        self.id = id
        self.role = role
        self.name = name
    }
}

public enum ClaudeWebUsageClientError: Error, Equatable {
    /// 401 / 403 — cookie is missing, expired, or rejected.
    case unauthorized
    /// 429 — back off and try again later.
    case rateLimited(retryAfter: TimeInterval?)
    /// 200 OK but the response body doesn't decode into the expected shape.
    case schemaMismatch(reason: String)
    /// Any other non-2xx status.
    case httpError(status: Int)
    /// URLSession-level transport error (timeouts, no connection, etc.).
    case transportError(message: String)
    /// Cookie value was empty.
    case missingCookie

    public var localizedDescription: String {
        switch self {
        case .unauthorized:
            return "Claude session cookie is missing, expired, or rejected (HTTP 401/403)."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return "Rate limited by claude.ai. Retry after \(Int(retryAfter)) seconds."
            }
            return "Rate limited by claude.ai."
        case let .schemaMismatch(reason):
            return "Unexpected response from claude.ai: \(reason)"
        case let .httpError(status):
            return "claude.ai returned HTTP \(status)."
        case let .transportError(message):
            return "Network error talking to claude.ai: \(message)"
        case .missingCookie:
            return "No Claude session cookie configured."
        }
    }
}

public struct ClaudeWebUsageClient: ClaudeWebUsageFetching {
    public static let defaultBaseURL = URL(string: "https://claude.ai")!
    public static let defaultUserAgent = "OpenIsland/1.0 (+https://github.com/Octane0411/open-vibe-island)"

    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String

    public init(
        session: URLSession = .shared,
        baseURL: URL = ClaudeWebUsageClient.defaultBaseURL,
        userAgent: String = ClaudeWebUsageClient.defaultUserAgent
    ) {
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    public func fetchOrganizations(cookie: String) async throws -> [ClaudeWebOrganization] {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("organizations")
        let data = try await performGET(url: url, cookie: cookie)

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClaudeWebUsageClientError.schemaMismatch(reason: "expected an array at /api/organizations")
        }

        let orgs: [ClaudeWebOrganization] = array.compactMap { dict in
            guard let id = dict["uuid"] as? String ?? dict["id"] as? String, !id.isEmpty else {
                return nil
            }
            return ClaudeWebOrganization(
                id: id,
                role: dict["role"] as? String,
                name: dict["name"] as? String
            )
        }

        guard !orgs.isEmpty else {
            throw ClaudeWebUsageClientError.schemaMismatch(reason: "no usable organizations in response")
        }
        return orgs
    }

    public func fetchUsageRaw(cookie: String, organizationID: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("organizations")
            .appendingPathComponent(organizationID)
            .appendingPathComponent("usage")
        let data = try await performGET(url: url, cookie: cookie)

        // Sanity-check schema: must be a JSON object with at least
        // five_hour or seven_day keys. Anything else means the endpoint
        // moved or schema drifted; fail-closed and let the poller fall
        // back to the statusline-fed cache.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeWebUsageClientError.schemaMismatch(reason: "usage response is not a JSON object")
        }
        guard object["five_hour"] != nil || object["seven_day"] != nil else {
            throw ClaudeWebUsageClientError.schemaMismatch(reason: "usage response missing five_hour and seven_day")
        }
        return data
    }

    // MARK: - Internal

    private func performGET(url: URL, cookie: String) async throws -> Data {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeWebUsageClientError.missingCookie
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(trimmed, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeWebUsageClientError.transportError(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeWebUsageClientError.transportError(message: "non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw ClaudeWebUsageClientError.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "retry-after"))
                .flatMap(TimeInterval.init)
            throw ClaudeWebUsageClientError.rateLimited(retryAfter: retryAfter)
        default:
            throw ClaudeWebUsageClientError.httpError(status: http.statusCode)
        }
    }
}
