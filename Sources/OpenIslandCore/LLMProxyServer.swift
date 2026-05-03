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

    public init(
        port: UInt16 = 9710,
        anthropicUpstream: URL = URL(string: "https://api.anthropic.com")!,
        openAIUpstream: URL = URL(string: "https://api.openai.com")!
    ) {
        self.port = port
        self.anthropicUpstream = anthropicUpstream
        self.openAIUpstream = openAIUpstream
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

    public init(
        id: UUID,
        upstream: LLMUpstream,
        method: String,
        path: String,
        requestHeaders: [(name: String, value: String)],
        requestBody: Data,
        receivedAt: Date,
        userAgent: String?
    ) {
        self.id = id
        self.upstream = upstream
        self.method = method
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.receivedAt = receivedAt
        self.userAgent = userAgent
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
    /// Used by `LLMRequestRewriter.rewriteAuthorizationIfNeeded` to
    /// look up the per-provider Keychain credential when the upstream
    /// is non-Anthropic (e.g. DeepSeek). `nil` disables the rewrite —
    /// existing tests construct the server without this dependency
    /// because they target `api.anthropic.com` (or a stubbed protocol
    /// class) and don't need provider key lookup.
    private let credentialsStore: RouterCredentialsStore?

    public init(
        configuration: LLMProxyConfiguration = .default,
        additionalProtocolClasses: [AnyClass] = [],
        credentialsStore: RouterCredentialsStore? = nil
    ) {
        self.configuration = configuration
        self.credentialsStore = credentialsStore
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 600     // SSE streams can idle a while
        cfg.timeoutIntervalForResource = 3600   // ditto
        cfg.httpAdditionalHeaders = nil
        cfg.urlCache = nil
        // Test injection point: a URLProtocol subclass placed at the
        // head of `protocolClasses` intercepts every outbound request
        // *before* it reaches the network. Production code never sets
        // this — it stays an empty array and the OS default chain
        // (HTTP/HTTPS/etc.) handles upstream traffic unmodified.
        if !additionalProtocolClasses.isEmpty {
            cfg.protocolClasses = additionalProtocolClasses + (cfg.protocolClasses ?? [])
        }
        let delegate = ProxyURLSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(
            configuration: cfg,
            delegate: delegate,
            delegateQueue: nil
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
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Self.logger.info("LLM proxy ready on 127.0.0.1:\(self.configuration.port)")
                LLMProxyPIDFile.write()
            case let .failed(error):
                Self.logger.error("LLM proxy listener failed: \(error.localizedDescription)")
                LLMProxyPIDFile.clear()
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
        if head.path == "/healthz" || head.path == "/healthz/" {
            respondLocally(
                state: state,
                status: 200,
                body: "ok\n",
                contentType: "text/plain; charset=utf-8"
            )
            return
        }

        let upstream = LLMUpstreamRouter.route(
            path: head.path,
            headers: head.lowercasedHeaders
        )
        let upstreamBase: URL
        switch upstream {
        case .anthropic: upstreamBase = configuration.anthropicUpstream
        case .openai: upstreamBase = configuration.openAIUpstream
        case .unknown:
            respondLocally(
                state: state,
                status: 421,
                body: #"{"error":"misdirected request — could not infer upstream from path or headers"}"#
            )
            return
        }

        // Apply the single permitted body mutation. See LLMRequestRewriter
        // for the full rationale.
        let outboundBody: Data
        if upstream == .openai, LLMRequestRewriter.shouldRewrite(path: head.path) {
            outboundBody = LLMRequestRewriter.rewrittenChatCompletionsBody(body)
        } else {
            outboundBody = body
        }

        let context = LLMProxyRequestContext(
            id: UUID(),
            upstream: upstream,
            method: head.method,
            path: head.path,
            requestHeaders: head.headers,
            requestBody: outboundBody,
            receivedAt: Date(),
            userAgent: head.header("user-agent")
        )

        if let observer {
            let captured = observer
            let ctx = context
            Task { await captured.proxyWillForward(ctx) }
        }

        forward(context: context, upstreamBase: upstreamBase, state: state)
    }

    // MARK: - Forwarding

    private func forward(
        context: LLMProxyRequestContext,
        upstreamBase: URL,
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
        if let store = credentialsStore {
            LLMRequestRewriter.rewriteAuthorizationIfNeeded(
                &forwardHeaders,
                upstreamURL: url,
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

        let task = session.dataTask(with: req)
        let handler = ProxyTaskHandler(
            context: context,
            connection: state.connection,
            queue: queue,
            observer: observer,
            logger: Self.logger
        )
        sessionDelegate.register(task: task, handler: handler)
        task.resume()
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
    /// Both `https://api.openai.com` + `/v1/responses` and
    /// `https://api2.tabcode.cc/openai/plus` + `/v1/responses` need to
    /// produce sensible URLs. We trim a trailing slash off the base,
    /// ensure the request target starts with one, and concat as
    /// strings — the request-target already includes any query string
    /// verbatim from the wire, so URLComponents would just complicate.
    static func combineUpstream(base: URL, requestTarget: String) -> URL? {
        var baseString = base.absoluteString
        if baseString.hasSuffix("/") { baseString.removeLast() }
        let suffix = requestTarget.hasPrefix("/") ? requestTarget : "/" + requestTarget
        return URL(string: baseString + suffix)
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
        h.handleResponseHead(httpResp)
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        handler(for: dataTask)?.handleResponseChunk(data)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let h = handler(for: task) {
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
    let logger: Logger
    private var sentHeaders = false

    init(
        context: LLMProxyRequestContext,
        connection: NWConnection,
        queue: DispatchQueue,
        observer: (any LLMProxyObserver)?,
        logger: Logger
    ) {
        self.context = context
        self.connection = connection
        self.queue = queue
        self.observer = observer
        self.logger = logger
    }

    func handleResponseHead(_ resp: HTTPURLResponse) {
        let status = resp.statusCode
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
        sentHeaders = true
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
        if let error, !sentHeaders {
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
        if let captured = observer {
            let ctx = context
            let err = error
            Task { await captured.proxy(ctx, didCompleteWithError: err) }
        }
    }
}
