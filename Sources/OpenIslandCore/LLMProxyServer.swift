import Foundation
import Network
import os

// MARK: - Configuration

public struct LLMProxyConfiguration: Sendable {
    public var port: UInt16
    /// Upstream base URLs. The request path from the inbound HTTP/1.1
    /// request gets concatenated onto these — so a base of
    /// `https://api2.tabcode.cc/openai/plus` plus a path of
    /// `/v1/responses` ends up as
    /// `https://api2.tabcode.cc/openai/plus/v1/responses`. This is what
    /// makes the proxy work with any OpenAI-compatible gateway, not
    /// just api.openai.com.
    public var anthropicUpstream: URL
    public var openAIUpstream: URL
    /// The proxy should not inherit macOS's system proxy settings by
    /// default. A local LLM proxy is already an explicit routing
    /// layer; letting CFNetwork auto-discover PAC / NetworkExtension
    /// proxy state has caused URLSession tasks to stall before any
    /// outbound socket is opened on systems running Clash-style global
    /// proxies. Set `OPEN_ISLAND_LLM_PROXY_USE_SYSTEM_PROXY=1` when
    /// diagnosing or when an upstream truly requires the system proxy.
    public var bypassSystemProxy: Bool
    /// Deadline for the first upstream response headers. Long-lived
    /// SSE streams remain supported because this watchdog disarms as
    /// soon as URLSession delivers response headers; it only prevents
    /// pre-connect / proxy-resolution stalls from black-holing the
    /// local client connection.
    public var upstreamFirstByteTimeout: TimeInterval

    public init(
        port: UInt16 = 9710,
        anthropicUpstream: URL = URL(string: "https://api.anthropic.com")!,
        openAIUpstream: URL = URL(string: "https://api.openai.com")!,
        bypassSystemProxy: Bool = true,
        upstreamFirstByteTimeout: TimeInterval = 30
    ) {
        self.port = port
        self.anthropicUpstream = anthropicUpstream
        self.openAIUpstream = openAIUpstream
        self.bypassSystemProxy = bypassSystemProxy
        self.upstreamFirstByteTimeout = upstreamFirstByteTimeout
    }

    public static let `default` = LLMProxyConfiguration()
}

// MARK: - Per-request context

public struct LLMProxyRequestContext: Sendable {
    public let id: UUID
    public let upstream: LLMUpstream
    public let method: String
    public let path: String
    public let requestHeaders: [(name: String, value: String)]
    public let requestBody: Data
    public let receivedAt: Date
    public let userAgent: String?
    /// Profile id this request was resolved against, captured at
    /// `handleParsedRequest` entry. Stable for the request lifetime
    /// even if the GUI's active profile flips mid-flight. `nil` only
    /// when the proxy was constructed without a `profileResolver`
    /// (legacy / test paths that do not exercise routing).
    public let resolvedProfileId: String?
    /// Whether `resolvedProfileId` came from the GUI active default
    /// or a per-request override (URL sentinel in T3+). Observers
    /// use this to label spend records.
    public let profileSelectionSource: ProfileSelectionSource?

    public init(
        id: UUID,
        upstream: LLMUpstream,
        method: String,
        path: String,
        requestHeaders: [(name: String, value: String)],
        requestBody: Data,
        receivedAt: Date,
        userAgent: String?,
        resolvedProfileId: String? = nil,
        profileSelectionSource: ProfileSelectionSource? = nil
    ) {
        self.id = id
        self.upstream = upstream
        self.method = method
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.receivedAt = receivedAt
        self.userAgent = userAgent
        self.resolvedProfileId = resolvedProfileId
        self.profileSelectionSource = profileSelectionSource
    }
}

// MARK: - Observer protocol

/// Observer hook for traffic. P0.1 leaves this empty; P0.2 hangs the
/// usage tracker off these callbacks. Async because the tracker writes
/// JSON to disk and shouldn't block the proxy's hot path.
public protocol LLMProxyObserver: AnyObject, Sendable {
    func proxyWillForward(_ context: LLMProxyRequestContext) async
    func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseStatus status: Int,
        headers: [String: String]
    ) async
    func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseChunk chunk: Data
    ) async
    func proxy(
        _ context: LLMProxyRequestContext,
        didCompleteWithError error: (any Error)?
    ) async
}

// MARK: - Server

public final class LLMProxyServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMProxy")

    public let configuration: LLMProxyConfiguration

    private let queue = DispatchQueue(label: "app.openisland.llm-proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var observer: (any LLMProxyObserver)?
    private let session: URLSession
    private let sessionDelegate: ProxyURLSessionDelegate
    private let sessionDelegateQueue: OperationQueue
    /// Used by `LLMRequestRewriter.rewriteAuthorizationIfNeeded` to
    /// look up the per-provider Keychain credential when the upstream
    /// is non-Anthropic (e.g. DeepSeek). `nil` disables the rewrite —
    /// existing tests construct the server without this dependency
    /// because they target `api.anthropic.com` (or a stubbed protocol
    /// class) and don't need provider key lookup.
    private let credentialsStore: RouterCredentialsStore?
    /// Routing-table resolver. Pairs with `credentialsStore`; both
    /// must be set for the Authorization rewrite to fire (a missing
    /// resolver means we have no way to decide which profile applies,
    /// and a missing store means we have no way to read the key).
    private let profileResolver: (any UpstreamProfileResolver)?
    /// Sliding-window outcome recorder consumed by the routing pane
    /// to surface "your active upstream is degraded" banners. `nil`
    /// disables recording — preserves test ergonomics for
    /// integration suites that don't care about health metrics.
    private let healthMonitor: LLMUpstreamHealthMonitor?

    public init(
        configuration: LLMProxyConfiguration = .default,
        additionalProtocolClasses: [AnyClass] = [],
        credentialsStore: RouterCredentialsStore? = nil,
        profileResolver: (any UpstreamProfileResolver)? = nil,
        healthMonitor: LLMUpstreamHealthMonitor? = nil
    ) {
        self.configuration = configuration
        self.credentialsStore = credentialsStore
        self.profileResolver = profileResolver
        self.healthMonitor = healthMonitor
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 600     // SSE streams can idle a while
        cfg.timeoutIntervalForResource = 3600   // ditto
        cfg.httpAdditionalHeaders = nil
        cfg.urlCache = nil
        let bypassSystemProxy = Self.effectiveBypassSystemProxy(
            configured: configuration.bypassSystemProxy
        )
        if bypassSystemProxy {
            // Explicitly avoid CFNetwork's system proxy resolver for
            // the forward path. This keeps LLMProxyServer from hanging
            // inside NetworkExtension / PAC resolution before an
            // outbound socket exists. Users who need the system proxy
            // can opt back in with OPEN_ISLAND_LLM_PROXY_USE_SYSTEM_PROXY=1.
            cfg.connectionProxyDictionary = [:]
        }
        // Test injection point: a URLProtocol subclass placed at the
        // head of `protocolClasses` intercepts every outbound request
        // *before* it reaches the network. Production code never sets
        // this — it stays an empty array and the OS default chain
        // (HTTP/HTTPS/etc.) handles upstream traffic unmodified.
        if !additionalProtocolClasses.isEmpty {
            cfg.protocolClasses = additionalProtocolClasses + (cfg.protocolClasses ?? [])
        }
        let delegate = ProxyURLSessionDelegate()
        let delegateQueue = OperationQueue()
        delegateQueue.name = "app.openisland.llm-proxy.urlsession"
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.maxConcurrentOperationCount = 8
        self.sessionDelegate = delegate
        self.sessionDelegateQueue = delegateQueue
        self.session = URLSession(
            configuration: cfg,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        Self.logger.info(
            "LLM proxy URLSession configured: delegateQueue=app.openisland.llm-proxy.urlsession maxConcurrent=8 bypassSystemProxy=\(bypassSystemProxy, privacy: .public) firstByteTimeout=\(configuration.upstreamFirstByteTimeout, privacy: .public)s"
        )
    }

    /// Bound port after `start()`, available once the listener has
    /// transitioned to `.ready`. Tests use this to discover the
    /// kernel-assigned port when `configuration.port == 0`. Returns
    /// `nil` before the listener is ready or after `stop()`.
    public var actualPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Block (asynchronously) until the listener has bound a port.
    /// Polls every 20 ms; throws after `timeout` seconds. Test helper.
    public func waitUntilReady(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = actualPort, port > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(
            domain: "app.openisland.llm-proxy",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "listener did not become ready within \(timeout)s"]
        )
    }

    public func setObserver(_ observer: (any LLMProxyObserver)?) {
        queue.sync { self.observer = observer }
    }

    static func effectiveBypassSystemProxy(
        configured: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["OPEN_ISLAND_LLM_PROXY_USE_SYSTEM_PROXY"] == "1" {
            return false
        }
        if environment["OPEN_ISLAND_LLM_PROXY_BYPASS_SYSTEM_PROXY"] == "1" {
            return true
        }
        return configured
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        let listener: NWListener
        if configuration.port == 0 {
            // Kernel-assigned ephemeral port — used by integration
            // tests so they don't fight over the production 9710.
            // `actualPort` exposes the bound value once ready.
            listener = try NWListener(using: params)
        } else {
            guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
                throw NSError(
                    domain: "app.openisland.llm-proxy",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid port \(configuration.port)"]
                )
            }
            listener = try NWListener(using: params, on: port)
        }
        // Cap concurrent connections so a misbehaving (or malicious)
        // local process can't exhaust per-process file descriptors
        // by opening N sockets to 9710. 64 sits well above realistic
        // Claude Code concurrency (1-4 simultaneous streams) and
        // well below macOS's default per-process FD ceiling
        // (256–10240). NWListener silently drops connections beyond
        // the limit; legitimate clients see a transient connect
        // failure and retry.
        listener.newConnectionLimit = 64
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Self.logger.info("LLM proxy ready on 127.0.0.1:\(self.configuration.port)")
                LLMProxyPIDFile.write()
            case let .failed(error):
                // SELF-HEAL: when the kernel poisons the listener
                // (resource exhaustion, kernel TCP error, etc.) the
                // socket fd stays open — `lsof` still shows LISTEN
                // — but accept() never fires again. Without this
                // recovery branch the proxy dies silently after
                // long uptime: clients get HTTP timeouts forever
                // until a manual restart. Cancel the dead listener
                // and re-bind on the same queue. Recursive `start()`
                // is bounded by the kernel's ability to bind the
                // port; if rebind itself fails we'll log and stop
                // (won't loop on an unbindable port).
                Self.logger.error("LLM proxy listener failed: \(error.localizedDescription) — attempting self-heal restart")
                LLMProxyPIDFile.clear()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    do {
                        try self.start()
                        Self.logger.info("LLM proxy listener self-heal succeeded")
                    } catch {
                        Self.logger.error("LLM proxy listener self-heal FAILED — proxy is now dead until app restart: \(error.localizedDescription)")
                    }
                }
            case .cancelled:
                Self.logger.info("LLM proxy listener cancelled")
                LLMProxyPIDFile.clear()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            LLMProxyPIDFile.clear()
        }
    }

    // MARK: - Connection lifecycle

    private func handleNewConnection(_ connection: NWConnection) {
        let state = ProxyConnectionState(connection: connection)
        connection.stateUpdateHandler = { [weak self] connState in
            switch connState {
            case let .failed(error):
                Self.logger.debug("connection failed: \(error.localizedDescription)")
                self?.queue.async { connection.cancel() }
            case let .waiting(error):
                // On loopback, .waiting should not occur during normal
                // operation. If it does, log for diagnostics but do NOT
                // cancel the connection — a forwarded URLSession task may
                // be in flight and needs the connection alive.
                // Resource cleanup happens in ProxyTaskHandler.
                Self.logger.debug("connection waiting (not cancelling): \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(state: state)
    }

    /// Read until we have full headers + full body, then forward. We do
    /// not impose an upper bound on body size — multi-MB Claude Code
    /// prompts are normal. The 64 KiB receive size is a per-call read
    /// budget, not a request cap.
    private func receiveRequest(state: ProxyConnectionState) {
        state.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let chunk, !chunk.isEmpty {
                state.buffer.append(chunk)
            }
            if let error {
                Self.logger.debug("recv error: \(error.localizedDescription)")
                state.connection.cancel()
                return
            }

            if state.head == nil {
                guard let terminator = LLMProxyHTTP.findHeaderTerminator(in: state.buffer) else {
                    if isComplete { state.connection.cancel(); return }
                    self.receiveRequest(state: state)
                    return
                }
                let headerBytes = state.buffer.subdata(in: 0..<terminator)
                do {
                    state.head = try LLMProxyHTTP.parseRequestHead(headerBytes)
                } catch {
                    self.respondLocally(
                        state: state,
                        status: 400,
                        body: #"{"error":"malformed request headers"}"#
                    )
                    return
                }
                state.bodyStart = terminator + 4
            }

            guard let head = state.head else {
                if isComplete { state.connection.cancel(); return }
                self.receiveRequest(state: state)
                return
            }

            let bodyData = state.buffer.subdata(in: state.bodyStart..<state.buffer.count)

            if head.isChunked {
                switch LLMProxyHTTP.decodeChunkedBody(bodyData) {
                case .needMore:
                    // Defensive: if the caller is buffering a slow
                    // chunked stream, never let `state.buffer` grow
                    // past the cap. The decoder's own `.tooLarge`
                    // gate fires once the *decoded* body crosses the
                    // line; this gate fires earlier on the *raw*
                    // bytes, in case the stream is mostly chunk
                    // metadata without ever flushing a full chunk.
                    if state.buffer.count > LLMProxyHTTP.inboundBodyCapBytes {
                        self.respondLocally(
                            state: state,
                            status: 413,
                            body: #"{"error":"request body exceeds 64 MiB cap"}"#
                        )
                        return
                    }
                    if isComplete { state.connection.cancel(); return }
                    self.receiveRequest(state: state)
                case let .complete(body, _):
                    self.handleParsedRequest(state: state, head: head, body: body)
                case .malformed:
                    self.respondLocally(
                        state: state,
                        status: 400,
                        body: #"{"error":"malformed chunked body"}"#
                    )
                case .tooLarge:
                    self.respondLocally(
                        state: state,
                        status: 413,
                        body: #"{"error":"request body exceeds 64 MiB cap"}"#
                    )
                }
            } else {
                let cl = head.contentLength ?? 0
                // Reject the request as soon as we know the declared
                // size is over the cap — no point reading further.
                if cl > LLMProxyHTTP.inboundBodyCapBytes {
                    self.respondLocally(
                        state: state,
                        status: 413,
                        body: #"{"error":"request body exceeds 64 MiB cap"}"#
                    )
                    return
                }
                if bodyData.count >= cl {
                    let body = Data(bodyData.prefix(cl))
                    self.handleParsedRequest(state: state, head: head, body: body)
                } else {
                    // Same defensive raw-byte gate the chunked path
                    // uses: in case `Content-Length` is absent or
                    // smaller than the actual stream, stop growing
                    // the buffer past the cap.
                    if state.buffer.count > LLMProxyHTTP.inboundBodyCapBytes {
                        self.respondLocally(
                            state: state,
                            status: 413,
                            body: #"{"error":"request body exceeds 64 MiB cap"}"#
                        )
                        return
                    }
                    if isComplete { state.connection.cancel(); return }
                    self.receiveRequest(state: state)
                }
            }
        }
    }

    private func handleParsedRequest(
        state: ProxyConnectionState,
        head: LLMProxyHTTP.RequestHead,
        body: Data
    ) {
        // Parse URL sentinels BEFORE any path-based decisions. Two
        // mutually exclusive sentinels:
        //   /_oi/profile/<id>/...   — claude-3's OI_PROFILE override
        //   /_oi/family/<family>/...— claude-deep's family constraint
        // Run both parsers in series; at most one matches because the
        // shim emits one or the other. Everything downstream uses the
        // cleaned `requestPath`, never head.path, so upstream never
        // sees the sentinel.
        let (requiredFamily, pathAfterFamily) = Self.parseFamilySentinel(path: head.path)
        let (overrideId, requestPath) = Self.parseSentinel(path: pathAfterFamily)

        if requestPath == "/healthz" || requestPath == "/healthz/" {
            respondLocally(
                state: state,
                status: 200,
                body: "ok\n",
                contentType: "text/plain; charset=utf-8"
            )
            return
        }

        // Resolve the profile once at request entry. Three branches:
        //  - overrideId set     → existing T3/T4 path (profile id wins
        //                          even if a family constraint was also
        //                          parsed; defensive — shim never emits
        //                          both, but this keeps the precedence
        //                          explicit).
        //  - requiredFamily set → claude-deep path: GUI-active profile
        //                          must satisfy `id.hasPrefix("<family>-")`.
        //  - neither            → plain GUI-active default.
        // Errors map to structured 400s so users see the actionable
        // hint at the proxy edge instead of a confusing upstream 401.
        let resolved: ResolvedProfile?
        if let resolver = profileResolver {
            do {
                if let overrideId {
                    resolved = try resolver.resolveProfile(overrideId: overrideId)
                } else if let requiredFamily {
                    resolved = try resolver.resolveProfile(requiringFamily: requiredFamily)
                } else {
                    resolved = try resolver.resolveProfile(overrideId: nil)
                }
            } catch UpstreamProfileResolverError.unknownOverride(let id) {
                respondLocally(
                    state: state,
                    status: 400,
                    body: Self.makeUnknownOverrideBody(
                        id: id,
                        available: resolver.availableProfileIds()
                    )
                )
                return
            } catch UpstreamProfileResolverError.familyMismatch(let family, let activeId) {
                let matching = resolver.availableProfileIds()
                    .filter { $0.hasPrefix(family + "-") }
                respondLocally(
                    state: state,
                    status: 400,
                    body: Self.makeFamilyMismatchBody(
                        requiredFamily: family,
                        activeId: activeId,
                        matchingAvailable: matching
                    )
                )
                return
            } catch {
                respondLocally(
                    state: state,
                    status: 500,
                    body: #"{"type":"error","error":{"type":"open_island_internal","message":"profile resolution failed unexpectedly"}}"#
                )
                return
            }
        } else {
            resolved = nil
        }

        let upstream = LLMUpstreamRouter.route(
            path: requestPath,
            headers: head.lowercasedHeaders
        )
        let upstreamBase: URL
        switch upstream {
        case .anthropic:
            upstreamBase = upstreamForAnthropic(resolved: resolved)
            if isAnthropicPassthroughBlocked(
                upstreamBase: upstreamBase,
                resolved: resolved
            ) {
                respondLocally(
                    state: state,
                    status: 409,
                    body: Self.anthropicOAuthBlockedBody
                )
                return
            }
        case .openai: upstreamBase = configuration.openAIUpstream
        case .unknown:
            respondLocally(
                state: state,
                status: 421,
                body: #"{"error":"misdirected request — could not infer upstream from path or headers"}"#
            )
            return
        }

        // Apply the audited body mutations. See LLMRequestRewriter
        // for the full rationale (items #2 and #4 of the audit list).
        // Item #2 is OpenAI-only (chat/completions usage opt-in).
        // Item #4 is profile-driven model rewrite — covers Anthropic
        // and OpenAI paths alike since the resolved profile's
        // modelOverride applies to whatever the upstream expects.
        var outboundBody: Data = body
        if upstream == .openai, LLMRequestRewriter.shouldRewrite(path: requestPath) {
            outboundBody = LLMRequestRewriter.rewrittenChatCompletionsBody(outboundBody)
        }
        if let resolved {
            outboundBody = LLMRequestRewriter.rewriteModelFieldIfNeeded(
                outboundBody,
                path: requestPath,
                profile: resolved.profile
            )
        }

        let context = LLMProxyRequestContext(
            id: UUID(),
            upstream: upstream,
            method: head.method,
            // T3: `path` is the **stripped** path (sentinel removed).
            // Observers / pricing already key off this via
            // /v1/messages vs /v1/chat/completions vs /v1/responses
            // detection; passing the raw sentinel-bearing path would
            // break their endpoint recognition. Forwarding to upstream
            // also uses this stripped path.
            path: requestPath,
            requestHeaders: head.headers,
            requestBody: outboundBody,
            receivedAt: Date(),
            userAgent: head.header("user-agent"),
            resolvedProfileId: resolved?.profile.id,
            profileSelectionSource: resolved?.source
        )

        if let observer {
            let captured = observer
            let ctx = context
            Task { await captured.proxyWillForward(ctx) }
        }

        forward(
            context: context,
            upstreamBase: upstreamBase,
            resolved: resolved,
            state: state
        )
    }

    // MARK: - Active-profile routing

    /// Resolve the upstream URL for an Anthropic-format request,
    /// preferring the resolved profile's `baseURL` over the static
    /// `configuration.anthropicUpstream` field.
    ///
    /// The static `configuration.anthropicUpstream` predates the
    /// profile system. Semantics now:
    /// - When `resolved == nil` (no resolver wired): return the
    ///   static config value verbatim — preserves legacy test paths.
    /// - When the resolved profile is the built-in `anthropic-native`
    ///   AND the static config has been overridden away from the
    ///   built-in default (`https://api.anthropic.com`): use the
    ///   override. This is the self-hosted-gateway escape hatch
    ///   (LLMSpend settings → "Anthropic upstream URL") for users
    ///   pointing at an Anthropic-compatible proxy without
    ///   registering it as a custom profile.
    /// - For every other resolved profile (DeepSeek V4 Pro/Flash,
    ///   custom, or `anthropic-native` with default config): the
    ///   profile's own `baseURL` wins.
    ///
    /// T3 changed the parameter from "current active profile, read
    /// inline" to "resolved profile, passed in". Per-invocation
    /// override now naturally flows through this helper because
    /// `handleParsedRequest` passes the resolved profile (which may
    /// be from override) here.
    private func upstreamForAnthropic(resolved: ResolvedProfile?) -> URL {
        guard let profile = resolved?.profile else {
            return configuration.anthropicUpstream
        }
        if profile.id == BuiltinProfiles.anthropicNative.id {
            let configured = configuration.anthropicUpstream
            let defaultUpstream = BuiltinProfiles.anthropicNative.baseURL
            if configured != defaultUpstream {
                return configured
            }
        }
        return profile.baseURL
    }

    /// Mirror of `ModelRoutingDerivation.isBlocked` on the router
    /// hot path. A "blocked" Anthropic request is one that would
    /// be forwarded to `api.anthropic.com` carrying whatever
    /// Authorization header claude CLI happens to send — typically
    /// a Max/Pro OAuth token. Anthropic enforces end-to-end client
    /// identity verification on those tokens, so the request always
    /// 401s after a full round-trip; surfacing it as 409 here gives
    /// the user an actionable error pointing at the `claude-native`
    /// shim (which talks straight to api.anthropic.com without
    /// proxying).
    ///
    /// Self-hosted-gateway escape hatch is preserved: when the user
    /// has overridden `configuration.anthropicUpstream` away from
    /// the default `api.anthropic.com`, `resolvedAnthropicUpstream`
    /// already returns that override, so the host check below fails
    /// and we forward as usual.
    ///
    /// Returns `false` when `resolved == nil` (legacy callers
    /// without routing) — those paths trust the static config and
    /// shouldn't be regulated retroactively. T3 changed the input
    /// from "active profile, read inline" to "the resolved profile
    /// for this request" so per-invocation override is honored: if
    /// the override targets a passthrough Anthropic profile, the
    /// gate fires; if the override targets DeepSeek, the gate
    /// no-ops correctly even when the user's GUI active is
    /// passthrough.
    private func isAnthropicPassthroughBlocked(
        upstreamBase: URL,
        resolved: ResolvedProfile?
    ) -> Bool {
        guard let profile = resolved?.profile else { return false }
        guard upstreamBase.host?.lowercased() == "api.anthropic.com" else {
            return false
        }
        return profile.keychainAccount == nil
    }

    /// 409 body returned when `isAnthropicPassthroughBlocked` fires.
    /// JSON shape mirrors Anthropic's `{"type":"error","error":{...}}`
    /// envelope so well-behaved clients log it at the same call site
    /// they log upstream errors. The `error.type` namespace is
    /// `open_island_*` so a grep distinguishes proxy-side gates from
    /// upstream-issued errors.
    static let anthropicOAuthBlockedBody = #"{"type":"error","error":{"type":"open_island_oauth_blocked","message":"Anthropic OAuth credentials cannot pass through Open Island. Anthropic enforces end-to-end client identity verification on Max/Pro tokens which the proxy cannot relay. Run `claude` via the `claude-native` shim (~/.open-island/bin/claude-native) to bypass the proxy, or activate a profile with a stored API key (e.g. DeepSeek V4 Pro) in the routing pane."}}"#

    /// 400 body returned when the URL sentinel carried a profile id
    /// that the resolver does not know. JSON shape mirrors the
    /// Anthropic-style error envelope (matches the 409 OAuth body)
    /// so well-behaved clients log it via the same path they log
    /// upstream errors. The `available` array gives users a concrete
    /// list of valid alternatives so a typo is one fix away.
    /// Built at runtime because the unknown id and the available
    /// list are dynamic.
    static func makeUnknownOverrideBody(
        id: String,
        available: [String]
    ) -> String {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "unknown_open_island_profile",
                "id": id,
                "available": available,
                "message": "OI_PROFILE / URL sentinel referenced a profile id that is not registered. Pick one of the values in `available`, or omit OI_PROFILE to use the GUI-active profile."
            ] as [String: Any]
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let s = String(data: data, encoding: .utf8)
        else {
            // Defensive fallback. This should never trigger because
            // every value above is a String / [String], all of which
            // JSONSerialization handles natively. Keep the fallback
            // valid JSON so client error parsers do not blow up.
            return #"{"type":"error","error":{"type":"unknown_open_island_profile"}}"#
        }
        return s
    }

    /// 400 body returned when `claude-deep`'s family sentinel
    /// references a family that the GUI-active profile does not
    /// belong to (e.g. `/_oi/family/deepseek` while active is
    /// `anthropic-native`). Mirrors the unknown-override body shape
    /// — same `error.type` namespace prefix so log scrapers can grep
    /// for `open_island_*`. `matching_available` lists the registered
    /// profile ids that DO satisfy the constraint, so the user can
    /// pick one to switch to in the routing pane.
    static func makeFamilyMismatchBody(
        requiredFamily: String,
        activeId: String,
        matchingAvailable: [String]
    ) -> String {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "open_island_family_mismatch",
                "required_family": requiredFamily,
                "active_profile_id": activeId,
                "matching_available": matchingAvailable,
                "message": "claude-deep requires the `\(requiredFamily)` family to be GUI-active (any profile whose id starts with `\(requiredFamily)-`), but the active profile is `\(activeId)`. Pick a matching profile in the routing pane, or use `claude-3` which has no family constraint."
            ] as [String: Any]
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let s = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"error","error":{"type":"open_island_family_mismatch"}}"#
        }
        return s
    }

    // MARK: - Forwarding

    private func forward(
        context: LLMProxyRequestContext,
        upstreamBase: URL,
        resolved: ResolvedProfile?,
        state: ProxyConnectionState
    ) {
        guard let url = Self.combineUpstream(base: upstreamBase, requestTarget: context.path) else {
            respondLocally(
                state: state,
                status: 502,
                body: #"{"error":"invalid upstream url"}"#
            )
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = context.method
        // Apply audited header mutations to a mutable copy of the
        // incoming headers BEFORE forwarding. See LLMRequestRewriter
        // for the full audit list. Currently the only rewrite this
        // gates is the Authorization-for-DeepSeek path; if
        // `credentialsStore` is nil (no provider routing wired) it's
        // a no-op.
        var forwardHeaders = context.requestHeaders
        if let store = credentialsStore, let profile = resolved?.profile {
            LLMRequestRewriter.rewriteAuthorizationIfNeeded(
                &forwardHeaders,
                profile: profile,
                credentialsStore: store
            )
        }
        for (name, value) in forwardHeaders {
            let lower = name.lowercased()
            if LLMProxyHTTP.hopByHopHeaders.contains(lower) { continue }
            if lower == "host" { continue }            // URLSession sets Host
            if lower == "content-length" { continue }  // URLSession recomputes
            // URLSession transparently gunzips response bodies but leaves
            // Content-Encoding: gzip in the headers — that breaks any
            // downstream client that respects the header. Force identity
            // upstream so what URLSession hands us is what upstream sent.
            // This is a request-header rewrite, not a body mutation; the
            // semantic bytes the agent sees are unchanged.
            if lower == "accept-encoding" { continue }
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !context.requestBody.isEmpty {
            req.httpBody = context.requestBody
        }

        Self.logger.debug(
            "forward prepare id=\(context.id.uuidString, privacy: .public) method=\(context.method, privacy: .public) path=\(context.path, privacy: .public) upstreamHost=\(url.host ?? "-", privacy: .public) upstreamPath=\(url.path, privacy: .public)"
        )
        let task = session.dataTask(with: req)
        Self.logger.debug(
            "forward task created id=\(context.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public)"
        )
        let handler = ProxyTaskHandler(
            context: context,
            connection: state.connection,
            queue: queue,
            observer: observer,
            healthMonitor: healthMonitor,
            logger: Self.logger
        )
        sessionDelegate.register(task: task, handler: handler)
        installFirstByteWatchdogIfNeeded(task: task, handler: handler)
        Self.logger.debug(
            "forward task registered id=\(context.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public)"
        )
        task.resume()
        Self.logger.debug(
            "forward task resumed id=\(context.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public)"
        )
        // Once URLSession task is in flight, disable the connection's
        // stateUpdateHandler. ProxyTaskHandler now owns the connection
        // lifecycle and will manage cleanup via didCompleteWithError.
        // This prevents a race where .waiting would cancel the connection
        // mid-flight.
        state.connection.stateUpdateHandler = nil
    }

    private func installFirstByteWatchdogIfNeeded(
        task: URLSessionDataTask,
        handler: ProxyTaskHandler
    ) {
        let timeout = configuration.upstreamFirstByteTimeout
        guard timeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        let delegate = sessionDelegate
        timer.setEventHandler { [weak handler, weak task, weak delegate] in
            guard let handler, let task else { return }
            if handler.handleFirstByteTimeout(timeout: timeout) {
                task.cancel()
                delegate?.unregister(task: task)
            }
        }
        handler.setFirstByteWatchdog(timer)
        timer.resume()
    }

    // MARK: - Local responses

    private func respondLocally(
        state: ProxyConnectionState,
        status: Int,
        body: String,
        contentType: String = "application/json; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let header = LLMProxyHTTP.formatResponseHeader(
            statusCode: status,
            reasonPhrase: Self.reasonPhrase(for: status),
            headers: [
                ("Content-Type", contentType),
                ("Content-Length", "\(bodyData.count)"),
            ]
        )
        var packet = header
        packet.append(bodyData)
        state.connection.send(content: packet, isComplete: true, completion: .contentProcessed { _ in
            state.connection.cancel()
        })
    }

    /// Concatenate the upstream base URL with the inbound request-target.
    /// Rejects request-target segments containing ".." to prevent path
    /// traversal, and normalizes via URLComponents for safety against
    /// fragment/query injection through the base URL string.
    static func combineUpstream(base: URL, requestTarget: String) -> URL? {
        // Split inbound request target into path + query. Without this
        // split, a request-target like `/v1/messages?beta=true` is set
        // wholesale onto `comps.path`, where the `?` gets URL-encoded
        // to `%3F` and the upstream sees the literal path
        // `/v1/messages%3Fbeta=true` — an invalid URL that gateways
        // reject with 404. Claude Code 2.1.123+ sends `?beta=true`
        // for streaming/beta features against api.anthropic.com; the
        // proxy must preserve the query when forwarding.
        let rawPath: String
        let rawQuery: String?
        if let qIdx = requestTarget.firstIndex(of: "?") {
            rawPath = String(requestTarget[..<qIdx])
            rawQuery = String(requestTarget[requestTarget.index(after: qIdx)...])
        } else {
            rawPath = requestTarget
            rawQuery = nil
        }
        // Reject path traversal attempts before concatenation.
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains("..") { return nil }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let suffix = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        // Append the suffix to the existing path, normalizing "//" etc.
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + suffix
        // Reject URLs with fragments introduced by the base. Query is
        // now allowed: it comes from the inbound request and is set
        // explicitly below, overriding any base.query.
        guard comps.fragment == nil else {
            return nil
        }
        if let rawQuery, !rawQuery.isEmpty {
            comps.percentEncodedQuery = rawQuery
        }
        return comps.url
    }

    /// Per-invocation override sentinel: when the `claude-3` shim
    /// (T5) sets `ANTHROPIC_BASE_URL=http://127.0.0.1:9710/_oi/profile/<id>`
    /// from `$OI_PROFILE`, the inbound request-target arrives at the
    /// proxy as `/_oi/profile/<id>/v1/messages`. This helper splits
    /// that into the override id and the cleaned request-path the
    /// rest of the proxy operates on. Anything not starting with the
    /// sentinel prefix passes through unchanged with `overrideId =
    /// nil`. Empty ids (e.g. literal `/_oi/profile//...`) are
    /// rejected as malformed and treated as "no sentinel" — silent
    /// fallback is the right call here because matched-but-empty
    /// looks like a shim bug, not a user typo, and we'd rather
    /// degrade to the active default than 400 a request that was
    /// almost certainly fine. T4 will tighten the unknown-id case.
    static func parseSentinel(path: String) -> (overrideId: String?, requestPath: String) {
        let prefix = "/_oi/profile/"
        guard path.hasPrefix(prefix) else {
            return (nil, path)
        }
        let after = path.dropFirst(prefix.count)
        if let slash = after.firstIndex(of: "/") {
            let id = String(after[..<slash])
            let rest = String(after[slash...])
            if id.isEmpty {
                return (nil, path)
            }
            return (id, rest)
        }
        // Sentinel without a trailing path segment — the entire tail
        // is the id; treat the request-path as `/`. Useful for
        // probes like `curl /_oi/profile/<id>` (no further segments).
        let id = String(after)
        if id.isEmpty {
            return (nil, path)
        }
        return (id, "/")
    }

    /// Family-constraint sentinel: when the `claude-deep` shim sets
    /// `ANTHROPIC_BASE_URL=http://127.0.0.1:9710/_oi/family/<family>`,
    /// the inbound request-target arrives as `/_oi/family/<family>/v1/messages`.
    /// Returns the constrained family and the cleaned request-path.
    /// Same shape and same empty-segment fallback policy as
    /// `parseSentinel(path:)` — the two prefixes are mutually
    /// exclusive at the URL level (a single shim emits one or the
    /// other), so callers can run both parsers in series and trust
    /// that at most one returns a non-nil match.
    static func parseFamilySentinel(path: String) -> (requiredFamily: String?, requestPath: String) {
        let prefix = "/_oi/family/"
        guard path.hasPrefix(prefix) else {
            return (nil, path)
        }
        let after = path.dropFirst(prefix.count)
        if let slash = after.firstIndex(of: "/") {
            let family = String(after[..<slash])
            let rest = String(after[slash...])
            if family.isEmpty {
                return (nil, path)
            }
            return (family, rest)
        }
        let family = String(after)
        if family.isEmpty {
            return (nil, path)
        }
        return (family, "/")
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "OK"
        }
    }
}

// MARK: - Per-connection state

private final class ProxyConnectionState: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()
    var head: LLMProxyHTTP.RequestHead?
    var bodyStart = 0
    init(connection: NWConnection) {
        self.connection = connection
    }
}

// MARK: - URLSession delegate dispatcher

private final class ProxyURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: ProxyTaskHandler] = [:]

    func register(task: URLSessionTask, handler: ProxyTaskHandler) {
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
    }

    func unregister(task: URLSessionTask) {
        remove(task: task)
    }

    private func handler(for task: URLSessionTask) -> ProxyTaskHandler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    private func remove(task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Don't follow redirects — let the agent see them as-is.
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let h = handler(for: dataTask),
              let httpResp = response as? HTTPURLResponse
        else {
            completionHandler(.cancel)
            return
        }
        h.logger.debug(
            "forward didReceiveResponse id=\(h.context.id.uuidString, privacy: .public) task=\(dataTask.taskIdentifier, privacy: .public) status=\(httpResp.statusCode, privacy: .public)"
        )
        h.handleResponseHead(httpResp)
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if let h = handler(for: dataTask) {
            h.logger.debug(
                "forward didReceiveData id=\(h.context.id.uuidString, privacy: .public) task=\(dataTask.taskIdentifier, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            h.handleResponseChunk(data)
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let h = handler(for: task) {
            if let error {
                h.logger.debug(
                    "forward didComplete id=\(h.context.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            } else {
                h.logger.debug(
                    "forward didComplete id=\(h.context.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public) success"
                )
            }
            h.handleCompletion(error: error)
        }
        remove(task: task)
    }
}

// MARK: - Per-task handler

private final class ProxyTaskHandler: @unchecked Sendable {
    let context: LLMProxyRequestContext
    let connection: NWConnection
    let queue: DispatchQueue
    weak var observer: (any LLMProxyObserver)?
    /// Strong reference (not weak): the monitor's lifetime is tied
    /// to LLMProxyCoordinator and outlives any single request, so
    /// holding it from the per-task handler is fine and avoids the
    /// nil-during-callback race a weak reference would create.
    let healthMonitor: LLMUpstreamHealthMonitor?
    let logger: Logger
    private var sentHeaders = false
    private var completed = false
    private let lock = NSLock()
    private var firstByteWatchdog: DispatchSourceTimer?
    /// Last HTTP status the upstream returned. Drives the
    /// success/failure decision in `handleCompletion`.
    private var lastSeenStatus: Int?

    init(
        context: LLMProxyRequestContext,
        connection: NWConnection,
        queue: DispatchQueue,
        observer: (any LLMProxyObserver)?,
        healthMonitor: LLMUpstreamHealthMonitor?,
        logger: Logger
    ) {
        self.context = context
        self.connection = connection
        self.queue = queue
        self.observer = observer
        self.healthMonitor = healthMonitor
        self.logger = logger
    }

    func setFirstByteWatchdog(_ timer: DispatchSourceTimer) {
        lock.lock()
        firstByteWatchdog = timer
        lock.unlock()
    }

    @discardableResult
    func handleFirstByteTimeout(timeout: TimeInterval) -> Bool {
        lock.lock()
        if completed || sentHeaders {
            lock.unlock()
            return false
        }
        completed = true
        firstByteWatchdog = nil
        lock.unlock()

        logger.error(
            "forward first-byte timeout id=\(self.context.id.uuidString, privacy: .public) upstream=\(self.context.path, privacy: .public) timeout=\(timeout, privacy: .public)s"
        )
        let body = #"{"error":"upstream did not respond before first-byte timeout"}"#
        let bodyData = Data(body.utf8)
        let header = LLMProxyHTTP.formatResponseHeader(
            statusCode: 504,
            reasonPhrase: "Gateway Timeout",
            headers: [
                ("Content-Type", "application/json; charset=utf-8"),
                ("Content-Length", "\(bodyData.count)"),
            ]
        )
        var packet = header
        packet.append(bodyData)
        connection.send(content: packet, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        notifyCompletion(error: NSError(
            domain: "app.openisland.llm-proxy",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "upstream first-byte timeout after \(timeout)s"]
        ))
        healthMonitor?.record(success: false)
        return true
    }

    private func disarmFirstByteWatchdog() {
        lock.lock()
        let timer = firstByteWatchdog
        firstByteWatchdog = nil
        lock.unlock()
        timer?.cancel()
    }

    func handleResponseHead(_ resp: HTTPURLResponse) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        sentHeaders = true
        let timer = firstByteWatchdog
        firstByteWatchdog = nil
        lock.unlock()
        timer?.cancel()

        let status = resp.statusCode
        lastSeenStatus = status
        var headers: [(name: String, value: String)] = []
        var lower: [String: String] = [:]
        for (key, value) in resp.allHeaderFields {
            guard let k = key as? String, let v = value as? String else { continue }
            headers.append((name: k, value: v))
            lower[k.lowercased()] = v
        }
        let headerData = LLMProxyHTTP.formatResponseHeader(
            statusCode: status,
            reasonPhrase: LLMProxyServer.reasonPhrase(for: status),
            headers: headers
        )
        connection.send(content: headerData, completion: .contentProcessed { [logger] error in
            if let error {
                logger.warning("send response headers failed: \(error.localizedDescription)")
            }
        })
        if let captured = observer {
            let ctx = context
            let lowerCopy = lower
            Task { await captured.proxy(ctx, didReceiveResponseStatus: status, headers: lowerCopy) }
        }
    }

    func handleResponseChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let isCompleted = completed
        lock.unlock()
        guard !isCompleted else { return }
        connection.send(content: data, completion: .contentProcessed { [logger] error in
            if let error {
                logger.debug("send response chunk failed: \(error.localizedDescription)")
            }
        })
        if let captured = observer {
            let ctx = context
            let copy = data
            Task { await captured.proxy(ctx, didReceiveResponseChunk: copy) }
        }
    }

    func handleCompletion(error: (any Error)?) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        let alreadySentHeaders = sentHeaders
        lock.unlock()
        disarmFirstByteWatchdog()

        if let error, !alreadySentHeaders {
            // Upstream failed before any byte flowed — synthesize a 502 so
            // the agent sees a structured response instead of empty EOF.
            let body = #"{"error":"upstream connection failed: "# +
                error.localizedDescription
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") +
                #""}"#
            let bodyData = Data(body.utf8)
            let header = LLMProxyHTTP.formatResponseHeader(
                statusCode: 502,
                reasonPhrase: "Bad Gateway",
                headers: [
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Content-Length", "\(bodyData.count)"),
                ]
            )
            var packet = header
            packet.append(bodyData)
            connection.send(content: packet, isComplete: true, completion: .contentProcessed { _ in })
        }
        let connectionRef = connection
        connection.send(
            content: nil,
            isComplete: true,
            completion: .contentProcessed { [logger] sendErr in
                if let sendErr {
                    logger.debug("send EOF failed: \(sendErr.localizedDescription)")
                }
                connectionRef.cancel()
            }
        )
        notifyCompletion(error: error)
        // Health metric: success = no transport error AND a 2xx/3xx
        // upstream status. 4xx/5xx counts as failure (the user's
        // request did get to the upstream but the upstream told us
        // something went wrong — for routing-pane purposes that's
        // still a degraded experience). No status seen at all (e.g.
        // DNS failure, TCP reset) also counts as failure.
        if let monitor = healthMonitor {
            let ok: Bool = {
                guard error == nil, let status = lastSeenStatus else { return false }
                return (200..<400).contains(status)
            }()
            monitor.record(success: ok)
        }
    }

    private func notifyCompletion(error: (any Error)?) {
        if let captured = observer {
            let ctx = context
            let err = error
            Task { await captured.proxy(ctx, didCompleteWithError: err) }
        }
    }
}
