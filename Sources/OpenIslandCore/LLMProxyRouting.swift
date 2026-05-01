import Foundation

/// Which upstream provider a given request should be forwarded to. The
/// proxy serves both ANTHROPIC_BASE_URL and OPENAI_BASE_URL on the same
/// port, so we disambiguate per-request.
public enum LLMUpstream: String, Sendable, Codable {
    case anthropic
    case openai
    case unknown

    public var host: String? {
        switch self {
        case .anthropic: "api.anthropic.com"
        case .openai: "api.openai.com"
        case .unknown: nil
        }
    }
}

public enum LLMUpstreamRouter {
    /// Decide where to send `path`. Rules, in priority order:
    ///   1. Explicit `X-Open-Island-Upstream: anthropic|openai` header
    ///      (escape hatch for testing).
    ///   2. Path prefix — `/v1/messages`, `/v1/complete` → anthropic;
    ///      `/v1/chat/`, `/v1/responses`, and other OpenAI-only paths →
    ///      openai.
    ///   3. For shared paths (`/v1/models`, `/v1/embeddings` is OpenAI-only
    ///      but harmless to keep here): sniff `anthropic-version` /
    ///      `x-api-key: sk-ant-…` for Anthropic, else `Authorization:
    ///      Bearer …` → openai.
    ///   4. Fall through to `.unknown` — the server returns 421
    ///      Misdirected Request rather than guessing.
    public static func route(
        path: String,
        headers: [String: String]
    ) -> LLMUpstream {
        if let override = headers["x-open-island-upstream"]?.lowercased() {
            if override == "anthropic" { return .anthropic }
            if override == "openai" { return .openai }
        }
        let lp = path.lowercased()
        if lp.hasPrefix("/v1/messages") || lp.hasPrefix("/v1/complete") {
            return .anthropic
        }
        let openAIPrefixes = [
            "/v1/chat/",
            "/v1/responses",
            "/v1/embeddings",
            "/v1/audio",
            "/v1/images",
            "/v1/files",
            "/v1/assistants",
            "/v1/threads",
            "/v1/batches",
            "/v1/fine_tuning",
            "/v1/moderations",
            "/v1/uploads",
        ]
        for prefix in openAIPrefixes {
            if lp.hasPrefix(prefix) { return .openai }
        }

        if let _ = headers["anthropic-version"] {
            return .anthropic
        }
        if let key = headers["x-api-key"], key.hasPrefix("sk-ant") {
            return .anthropic
        }
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return .openai
        }
        return .unknown
    }
}
