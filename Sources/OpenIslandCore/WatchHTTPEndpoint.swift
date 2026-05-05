import Foundation
import Network
import os

// MARK: - SSE Event Types

/// Events pushed to connected iPhone clients via Server-Sent Events.
public enum WatchSSEEvent: Sendable {
    case permissionRequested(WatchPermissionEvent)
    case questionAsked(WatchQuestionEvent)
    case sessionCompleted(WatchCompletionEvent)
    /// Sent when an actionable request (permission/question) has been resolved on the Mac side.
    case actionableStateResolved(WatchResolvedEvent)

    func sseString() -> String {
        switch self {
        case let .permissionRequested(event):
            let data = (try? JSONEncoder().encode(event)) ?? Data()
            return "event: permissionRequested\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        case let .questionAsked(event):
            let data = (try? JSONEncoder().encode(event)) ?? Data()
            return "event: questionAsked\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        case let .sessionCompleted(event):
            let data = (try? JSONEncoder().encode(event)) ?? Data()
            return "event: sessionCompleted\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        case let .actionableStateResolved(event):
            let data = (try? JSONEncoder().encode(event)) ?? Data()
            return "event: actionableStateResolved\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        }
    }
}

public struct WatchPermissionEvent: Codable, Sendable {
    public var sessionID: String
    public var agentTool: String
    public var title: String
    public var summary: String
    public var workingDirectory: String?
    public var primaryAction: String
    public var secondaryAction: String
    public var requestID: String
}

public struct WatchQuestionEvent: Codable, Sendable {
    public var sessionID: String
    public var agentTool: String
    public var title: String
    public var options: [String]
    public var requestID: String
}

public struct WatchCompletionEvent: Codable, Sendable {
    public var sessionID: String
    public var agentTool: String
    public var summary: String
}

// MARK: - Resolved Event

/// Sent via SSE when an actionable request has been resolved on the Mac side.
public struct WatchResolvedEvent: Codable, Sendable {
    public var requestID: String
    public var sessionID: String

    public init(requestID: String, sessionID: String) {
        self.requestID = requestID
        self.sessionID = sessionID
    }
}

// MARK: - Resolution

public struct WatchResolutionRequest: Codable, Sendable {
    public var requestID: String
    public var action: String
}

// MARK: - Pairing

public struct WatchPairRequest: Codable, Sendable {
    public var code: String
}

public struct WatchPairResponse: Codable, Sendable {
    public var token: String
}

// MARK: - Status

public struct WatchStatusResponse: Codable, Sendable {
    public var connected: Bool
    public var activeSessionCount: Int
}

// MARK: - Resolution Handler

/// Callback invoked when the Watch/iPhone submits a resolution via `/resolution`.
public typealias WatchResolutionHandler = @Sendable (WatchResolutionRequest) -> Void

/// Callback to query current active session count for `/status`.
public typealias WatchActiveSessionCountProvider = @Sendable () -> Int

// MARK: - WatchHTTPEndpoint

/// A lightweight HTTP server embedded in the macOS app that enables iPhone/Watch communication.
///
/// Uses `NWListener` for TCP + Bonjour advertising of `_openisland._tcp`.
/// Implements a minimal HTTP/1.1 parser for 4 endpoints:
/// - `POST /pair` — submit 6-digit pairing code, receive session token
/// - `GET /events` — SSE stream of agent events
/// - `POST /resolution` — submit Watch action decisions
/// - `GET /status` — connection and session status
public final class WatchHTTPEndpoint: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.openisland", category: "WatchHTTPEndpoint")
    private static let serviceType = "_openisland._tcp"
    private static let pairingCodeLength = 6
    private static let pairingCodeExpiry: TimeInterval = 120 // 2 minutes
    private static let tokenExpiry: TimeInterval = 3600 // 1 hour

    // M-1/M-2: replay-protection knobs.
    //
    // Mutating endpoints (`/pair`, `/resolution`) require fresh
    // `X-OI-Nonce` (UUID, must never repeat) + `X-OI-Timestamp`
    // (unix epoch seconds, must be within ±skew of server clock)
    // headers. The window is generous enough to absorb watch ↔ Mac
    // clock skew without becoming a long-lived replay opportunity.
    /// Largest acceptable difference between the client-supplied
    /// `X-OI-Timestamp` and the server's wall clock.
    private static let nonceTimestampSkew: TimeInterval = 300 // 5 minutes
    /// LRU eviction window for already-seen nonces. Holds nonces
    /// for ~10 min (2× skew) so an attacker can't replay the
    /// instant the timestamp window slides.
    private static let nonceRetentionWindow: TimeInterval = 600
    /// Headers the client must send.
    static let nonceHeaderName = "X-OI-Nonce"
    static let timestampHeaderName = "X-OI-Timestamp"

    // Brute-force protection tunables. A 6-digit code is 1M values; combined
    // with a 5-minute rolling window of 10 failures per peer IP and a
    // 5-minute penalty box, a determined LAN attacker needs ~1000 years of
    // sustained guessing to exhaust the space — long enough that user
    // rotation (2-min expiry) and manual revocation dominate.
    private static let pairFailuresBeforeCodeRotation = 3
    private static let pairFailuresBeforeBlock = 10
    private static let pairFailureWindow: TimeInterval = 300
    private static let pairBlockDuration: TimeInterval = 300
    // Max request size we accept. The four JSON bodies this endpoint handles
    // are all tiny; anything bigger than 64 KiB is pathological.
    private static let maxRequestBytes = 64 * 1024

    private let queue = DispatchQueue(label: "app.openisland.watch.http", qos: .userInitiated)

    // Pairing state
    private var currentPairingCode: String = ""
    private var pairingCodeGeneratedAt: Date = .distantPast
    private var validTokens: [String: Date] = [:]

    // Per-peer brute-force accounting. Keyed by peer IP (not port) so a
    // determined attacker can't sidestep by rotating source ports.
    private struct PairAttemptLedger {
        var failures: [Date] = []
        var blockedUntil: Date = .distantPast
    }
    private var pairAttempts: [String: PairAttemptLedger] = [:]

    // SSE connections
    private var sseConnections: [UUID: NWConnection] = [:]

    // M-1/M-2 nonce ledger. Maps nonce string -> first-seen Date so
    // we can both reject replays and evict expired entries on read.
    // Plain dict keyed-by-time eviction is fine — the working set
    // is bounded by `nonceRetentionWindow / pair-cadence` which is
    // tiny (one watch + one phone, both serial).
    private var seenNonces: [String: Date] = [:]

    // Listeners (dual-stack: cleartext on `_openisland._tcp` for
    // legacy clients, TLS on the same service type but distinct
    // port advertised via TXT record `tls-port` for new clients).
    private var listener: NWListener?      // cleartext
    private var tlsListener: NWListener?   // TLS
    /// Identity backing the TLS listener, retained because
    /// `sec_identity_create_with_certificates` keeps a weak ref.
    private var tlsIdentity: WatchTLSIdentity.LoadResult?

    // Callbacks
    public var onResolution: WatchResolutionHandler?
    public var activeSessionCountProvider: WatchActiveSessionCountProvider?

    public init() {
        regeneratePairingCode()
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            self?.startListener()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.tlsListener?.cancel()
            self.tlsListener = nil
            self.tlsIdentity = nil
            for (id, connection) in self.sseConnections {
                connection.cancel()
                self.sseConnections.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Pairing Code

    /// Returns the current pairing code. Regenerates if expired.
    public func currentCode() -> String {
        queue.sync {
            if Date().timeIntervalSince(pairingCodeGeneratedAt) > Self.pairingCodeExpiry {
                regeneratePairingCodeUnsafe()
            }
            return currentPairingCode
        }
    }

    /// Force-regenerate pairing code (thread-safe).
    public func regeneratePairingCode() {
        queue.sync {
            regeneratePairingCodeUnsafe()
        }
    }

    /// Revoke all paired tokens, forcing re-pairing.
    public func revokeAllTokens() {
        queue.sync {
            validTokens.removeAll()
        }
    }

    // MARK: - SSE Push

    /// Push an SSE event to all authenticated, connected clients.
    public func pushEvent(_ event: WatchSSEEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = event.sseString()
            guard let data = payload.data(using: .utf8) else { return }
            for (id, connection) in self.sseConnections {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        Self.logger.warning("SSE send failed for \(id): \(error.localizedDescription)")
                    }
                })
            }
        }
    }

    // MARK: - Private: Listener

    private func startListener() {
        // C-3 dual-stack rollout: bring up TLS first so we know
        // the cert fingerprint by the time we publish the
        // cleartext listener's TXT record (which advertises the
        // TLS port + cert fingerprint to capable clients).
        //
        // Why both: existing iOS / watchOS clients in the wild
        // speak cleartext on `_openisland._tcp`. A flag-day
        // switch to TLS-only would brick those installs until a
        // companion App Store update propagates. Dual-stack keeps
        // legacy clients working while letting upgraded clients
        // see `tls=1` in the TXT record and re-connect to the
        // pinned-fingerprint TLS port.
        //
        // Threat model note: an active attacker can downgrade a
        // capable client to cleartext by suppressing the TXT
        // fields. Mitigated client-side: once a watch has paired
        // over TLS once, it must remember the fingerprint and
        // refuse subsequent cleartext connections. That's the
        // companion-app responsibility (audit C-3 follow-up).
        startTLSListenerIfPossible()
        startCleartextListener()
    }

    /// Bring up the TLS listener. Failure is logged but does NOT
    /// cancel the cleartext path — a cert-generation hiccup on a
    /// fresh box shouldn't block all watch traffic. Sets
    /// `tlsIdentity` on success so `startCleartextListener` can
    /// publish the fingerprint.
    private func startTLSListenerIfPossible() {
        let identity: WatchTLSIdentity.LoadResult
        do {
            identity = try WatchTLSIdentity.loadOrCreate()
        } catch {
            Self.logger.error("TLS identity init failed (\(error.localizedDescription, privacy: .public)) — falling back to cleartext-only mode")
            return
        }
        do {
            let tlsOptions = NWProtocolTLS.Options()
            // Force TLS 1.2 minimum; no PFS-less ciphers.
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )
            // Bind the self-signed identity. Apple's
            // `sec_identity_create` does not retain the SecIdentity
            // beyond the call, so we keep `tlsIdentity` on `self`
            // for the lifetime of the listener.
            guard let secIdentity = sec_identity_create(identity.identity) else {
                Self.logger.error("sec_identity_create returned nil — TLS listener disabled")
                return
            }
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                secIdentity
            )
            let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            params.requiredInterfaceType = .wifi
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.tlsListener?.port {
                        Self.logger.info("WatchHTTPEndpoint TLS listener ready on port \(port.rawValue) (fp=\(identity.fingerprint, privacy: .public))")
                    }
                case let .failed(error):
                    Self.logger.error("TLS listener failed: \(error.localizedDescription) — retry in 2 s")
                    self?.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.startTLSListenerIfPossible()
                    }
                case .cancelled:
                    Self.logger.info("TLS listener cancelled")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.start(queue: queue)
            tlsListener = listener
            tlsIdentity = identity
        } catch {
            Self.logger.error("TLS listener creation failed: \(error.localizedDescription)")
        }
    }

    /// Bring up the legacy cleartext listener. Always runs (even
    /// without TLS); when TLS is up, the TXT record advertises
    /// the TLS port + cert fingerprint so capable clients can
    /// upgrade. Backward-compatible for un-upgraded watch apps.
    private func startCleartextListener() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .wifi
            let listener = try NWListener(using: params)

            // Bonjour service: same name + type as before so the
            // legacy NWBrowser query keeps finding us. Capability
            // hints live in the TXT record — see
            // `makeBonjourTXTRecord` for the wire format.
            listener.service = NWListener.Service(
                name: "Open Island",
                type: Self.serviceType,
                txtRecord: makeBonjourTXTRecord()
            )

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port {
                        Self.logger.info("WatchHTTPEndpoint cleartext listener ready on port \(port.rawValue)")
                    }
                case let .failed(error):
                    Self.logger.error("Cleartext listener failed: \(error.localizedDescription) — retry in 2 s")
                    self?.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.startCleartextListener()
                    }
                case .cancelled:
                    Self.logger.info("Cleartext listener cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Self.logger.error("Failed to create cleartext NWListener: \(error.localizedDescription)")
        }
    }

    /// Bonjour TXT record fields:
    ///
    /// - `proto-version` — bumps when wire-format changes
    ///   (currently "1"). Lets a future client refuse outdated
    ///   servers.
    /// - `tls`           — "1" if a TLS listener is up, absent
    ///   otherwise. Bool flag.
    /// - `tls-port`      — decimal port of the TLS listener.
    ///   Present iff `tls=1`.
    /// - `cert-fp`       — SHA-256 fingerprint of the TLS cert,
    ///   uppercase hex without separators (64 chars). Client
    ///   pins this; mismatch on TLS handshake aborts.
    /// - `nonce-required` — "1" if mutating endpoints reject
    ///   requests without `X-OI-Nonce` + `X-OI-Timestamp`. Always
    ///   "1" once M-1/M-2 lands; included so future relax modes
    ///   are negotiable.
    private func makeBonjourTXTRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["proto-version"] = "1"
        txt["nonce-required"] = "1"
        if let tls = tlsIdentity, let port = tlsListener?.port {
            txt["tls"] = "1"
            txt["tls-port"] = String(port.rawValue)
            txt["cert-fp"] = tls.fingerprint
        }
        return txt
    }

    // MARK: - Private: Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    /// Accumulate request bytes until we have full headers (CRLFCRLF) plus
    /// the Content-Length body. Previously a single `receive` was assumed
    /// to carry the whole request; any TCP fragmentation or body > the
    /// first chunk silently produced a parse failure.
    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                Self.logger.debug("Connection receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let chunk = content, !chunk.isEmpty {
                accumulated.append(chunk)
            }

            if accumulated.count > Self.maxRequestBytes {
                self.sendHTTPResponse(connection: connection, status: "413 Payload Too Large", body: #"{"error":"request too large"}"#)
                return
            }

            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = accumulated.range(of: separator) else {
                if isComplete {
                    connection.cancel()
                    return
                }
                self.receiveHTTPRequest(on: connection, buffer: accumulated)
                return
            }

            let headerData = accumulated.subdata(in: 0..<headerEnd.lowerBound)
            let bodySoFar = accumulated.subdata(in: headerEnd.upperBound..<accumulated.count)

            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.sendHTTPResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"invalid request"}"#)
                return
            }

            let (method, path, headers) = Self.parseRequestLineAndHeaders(headerString)
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0

            if bodySoFar.count >= contentLength {
                let body: String? = contentLength > 0
                    ? String(data: bodySoFar.subdata(in: 0..<contentLength), encoding: .utf8)
                    : nil
                self.routeHTTPRequest(method: method, path: path, headers: headers, body: body, connection: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveHTTPRequest(on: connection, buffer: accumulated)
        }
    }

    // MARK: - Private: HTTP Routing

    private func routeHTTPRequest(method: String, path: String, headers: [String: String], body: String?, connection: NWConnection) {
        // M-1/M-2: nonce gate for mutating endpoints. We're in
        // "soft-enforce" mode: clients that send X-OI-Nonce +
        // X-OI-Timestamp get full replay protection; clients that
        // send neither are allowed through unchanged so the
        // already-shipped iOS / watchOS apps don't break. The
        // companion-app upgrade (Phase 3.5/3.6) will start
        // sending the headers; once everyone's upgraded we flip
        // this to hard-enforce.
        if method == "POST" && (path == "/pair" || path == "/resolution") {
            switch checkReplayProtection(headers: headers) {
            case .ok, .skipped:
                break
            case .badTimestamp:
                sendHTTPResponse(
                    connection: connection,
                    status: "400 Bad Request",
                    body: #"{"error":"timestamp out of acceptable window"}"#
                )
                return
            case .replay:
                sendHTTPResponse(
                    connection: connection,
                    status: "409 Conflict",
                    body: #"{"error":"nonce already used"}"#
                )
                return
            }
        }

        switch (method, path) {
        case ("POST", "/pair"):
            handlePair(body: body, connection: connection)

        case ("GET", "/events"):
            handleEventsSSE(headers: headers, connection: connection)

        case ("POST", "/resolution"):
            handleResolution(body: body, headers: headers, connection: connection)

        case ("GET", "/status"):
            handleStatus(headers: headers, connection: connection)

        default:
            sendHTTPResponse(connection: connection, status: "404 Not Found", body: #"{"error":"not found"}"#)
        }
    }

    // MARK: - Replay protection (M-1/M-2)

    enum ReplayCheckResult: Equatable {
        /// Both headers present and valid; nonce was recorded.
        case ok
        /// Neither nonce nor timestamp header was supplied. Soft
        /// mode lets these through; the route handler runs
        /// unchanged.
        case skipped
        /// Timestamp header present but outside the acceptable
        /// skew window (`±nonceTimestampSkew`).
        case badTimestamp
        /// Nonce was already seen within the retention window.
        case replay
    }

    /// Validate `X-OI-Nonce` + `X-OI-Timestamp` request headers.
    ///
    /// Header lookup is case-insensitive: HTTP/1.1 (RFC 7230 §3.2)
    /// declares header names case-insensitive, but the parser in
    /// this file lowercases everything anyway, so we just look up
    /// lowercase keys.
    ///
    /// Note that this method also opportunistically evicts nonces
    /// older than `nonceRetentionWindow` from the LRU dict — keeps
    /// memory bounded without a separate sweeper task.
    func checkReplayProtection(headers: [String: String]) -> ReplayCheckResult {
        let nonceHeader = headers[Self.nonceHeaderName.lowercased()]
        let tsHeader = headers[Self.timestampHeaderName.lowercased()]

        // Soft mode: if neither header is present, allow through.
        if nonceHeader == nil, tsHeader == nil {
            return .skipped
        }
        // If only one header is present, treat as malformed.
        guard let nonce = nonceHeader, !nonce.isEmpty,
              let tsString = tsHeader,
              let tsValue = TimeInterval(tsString)
        else {
            return .badTimestamp
        }

        let now = Date()
        // Evict expired entries before checking dup. Cheap O(N)
        // sweep; N is tiny (one watch + one phone, serial usage).
        let cutoff = now.addingTimeInterval(-Self.nonceRetentionWindow)
        seenNonces = seenNonces.filter { $0.value > cutoff }

        let clientDate = Date(timeIntervalSince1970: tsValue)
        if abs(now.timeIntervalSince(clientDate)) > Self.nonceTimestampSkew {
            return .badTimestamp
        }
        if seenNonces[nonce] != nil {
            return .replay
        }
        seenNonces[nonce] = now
        return .ok
    }

    // MARK: - Private: Endpoint Handlers

    private func handlePair(body: String?, connection: NWConnection) {
        let peerIP = Self.peerIP(for: connection)

        if let ledger = pairAttempts[peerIP], ledger.blockedUntil > Date() {
            sendHTTPResponse(connection: connection, status: "429 Too Many Requests", body: #"{"error":"too many failed attempts"}"#)
            return
        }

        guard let body, let bodyData = body.data(using: .utf8),
              let request = try? JSONDecoder().decode(WatchPairRequest.self, from: bodyData) else {
            sendHTTPResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"invalid body"}"#)
            return
        }

        // Per-peer rate-limit gate is at the top of handlePair via the
        // pairAttempts ledger; nothing extra to do here.
        let now = Date()

        // Check if pairing code expired
        if now.timeIntervalSince(pairingCodeGeneratedAt) > Self.pairingCodeExpiry {
            regeneratePairingCodeUnsafe()
            sendHTTPResponse(connection: connection, status: "410 Gone", body: #"{"error":"pairing code expired"}"#)
            return
        }

        guard Self.constantTimeEquals(request.code, currentPairingCode) else {
            recordPairFailure(peerIP: peerIP)
            sendHTTPResponse(connection: connection, status: "403 Forbidden", body: #"{"error":"invalid pairing code"}"#)
            return
        }

        // Success: wipe the peer's failure ledger, rotate the code, issue token with TTL.
        pairAttempts.removeValue(forKey: peerIP)
        let token = UUID().uuidString
        validTokens[token] = now.addingTimeInterval(Self.tokenExpiry)
        regeneratePairingCodeUnsafe()

        let response = WatchPairResponse(token: token)
        if let responseData = try? JSONEncoder().encode(response),
           let responseString = String(data: responseData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: "200 OK", body: responseString)
        }
    }

    private func handleEventsSSE(headers: [String: String], connection: NWConnection) {
        guard authenticateRequest(headers: headers) else {
            sendHTTPResponse(connection: connection, status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
            return
        }

        // Send SSE headers and keep connection open
        let sseHeaders = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """

        guard let headerData = sseHeaders.data(using: .utf8) else { return }

        let connectionID = UUID()
        sseConnections[connectionID] = connection

        let queue = self.queue
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            if let error {
                Self.logger.warning("Failed to send SSE headers: \(error.localizedDescription)")
                queue.async { [weak self] in
                    self?.sseConnections.removeValue(forKey: connectionID)
                }
                connection.cancel()
                return
            }

            // Send initial keepalive comment
            guard let keepalive = ": connected\n\n".data(using: .utf8) else { return }
            connection.send(content: keepalive, completion: .contentProcessed { _ in })
        })

        // Monitor for disconnect
        connection.viabilityUpdateHandler = { [weak self] isViable in
            if !isViable {
                queue.async { [weak self] in
                    self?.sseConnections.removeValue(forKey: connectionID)
                }
            }
        }

        // Detect connection close
        monitorSSEConnection(connectionID: connectionID, connection: connection)
    }

    private func monitorSSEConnection(connectionID: UUID, connection: NWConnection) {
        let queue = self.queue
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                queue.async { [weak self] in
                    self?.sseConnections.removeValue(forKey: connectionID)
                }
                connection.cancel()
            } else {
                self?.monitorSSEConnection(connectionID: connectionID, connection: connection)
            }
        }
    }

    private func handleResolution(body: String?, headers: [String: String], connection: NWConnection) {
        guard authenticateRequest(headers: headers) else {
            sendHTTPResponse(connection: connection, status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
            return
        }

        guard let body, let bodyData = body.data(using: .utf8),
              let request = try? JSONDecoder().decode(WatchResolutionRequest.self, from: bodyData) else {
            sendHTTPResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"invalid body"}"#)
            return
        }

        onResolution?(request)
        sendHTTPResponse(connection: connection, status: "200 OK", body: #"{"status":"accepted"}"#)
    }

    private func handleStatus(headers: [String: String], connection: NWConnection) {
        guard authenticateRequest(headers: headers) else {
            sendHTTPResponse(connection: connection, status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
            return
        }

        let response = WatchStatusResponse(
            connected: !sseConnections.isEmpty,
            activeSessionCount: activeSessionCountProvider?() ?? 0
        )

        if let responseData = try? JSONEncoder().encode(response),
           let responseString = String(data: responseData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: "200 OK", body: responseString)
        }
    }

    // MARK: - Private: Auth

    private func authenticateRequest(headers: [String: String]) -> Bool {
        guard let auth = headers["authorization"] ?? headers["Authorization"],
              auth.hasPrefix("Bearer ") else {
            return false
        }
        let token = String(auth.dropFirst("Bearer ".count))
        guard let expiry = validTokens[token] else {
            return false
        }
        if Date() > expiry {
            validTokens.removeValue(forKey: token)
            return false
        }
        return true
    }

    // MARK: - Private: Brute-force accounting

    /// Must be called on `queue`.
    private func recordPairFailure(peerIP: String) {
        let now = Date()
        var ledger = pairAttempts[peerIP] ?? PairAttemptLedger()

        ledger.failures = ledger.failures.filter { now.timeIntervalSince($0) < Self.pairFailureWindow }
        ledger.failures.append(now)

        if ledger.failures.count >= Self.pairFailuresBeforeBlock {
            ledger.blockedUntil = now.addingTimeInterval(Self.pairBlockDuration)
            regeneratePairingCodeUnsafe()
            Self.logger.warning("Pair attempts from \(peerIP, privacy: .public) blocked for \(Int(Self.pairBlockDuration))s after \(ledger.failures.count) failures")
        } else if ledger.failures.count >= Self.pairFailuresBeforeCodeRotation {
            regeneratePairingCodeUnsafe()
            Self.logger.info("Rotated pairing code after \(ledger.failures.count) failures from \(peerIP, privacy: .public)")
        }

        pairAttempts[peerIP] = ledger
    }

    private static func peerIP(for connection: NWConnection) -> String {
        switch connection.endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(addr):
                return "\(addr)"
            case let .ipv6(addr):
                return "\(addr)"
            case let .name(name, _):
                return name
            @unknown default:
                return "unknown"
            }
        default:
            return "unknown"
        }
    }

    /// Constant-time string comparison to avoid leaking pairing code prefix
    /// via timing side channels. Length mismatch short-circuits because the
    /// code length is a fixed, attacker-known constant anyway.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    // MARK: - Private: HTTP Helpers

    private static func parseRequestLineAndHeaders(_ header: String) -> (method: String, path: String, headers: [String: String]) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return ("", "", [:])
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        let method = requestParts.count > 0 ? String(requestParts[0]) : ""
        let path = requestParts.count > 1 ? String(requestParts[1]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return (method, path, headers)
    }

    private func sendHTTPResponse(connection: NWConnection, status: String, body: String, contentType: String = "application/json") {
        let bodyData = Data(body.utf8)
        let headerString = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(headerString.utf8)
        response.append(bodyData)

        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Private: Pairing Code Generation

    /// Must be called on `queue`.
    private func regeneratePairingCodeUnsafe() {
        let digits = (0..<Self.pairingCodeLength).map { _ in String(Int.random(in: 0...9)) }
        currentPairingCode = digits.joined()
        pairingCodeGeneratedAt = Date()
        // Per-peer ledger persists across rotations so attackers can't
        // reset their failure window by triggering a regen.
        pruneExpiredTokens()
        Self.logger.info("New pairing code generated")
    }

    private func pruneExpiredTokens() {
        let now = Date()
        let expired = validTokens.filter { $0.value <= now }.map(\.key)
        for token in expired {
            validTokens.removeValue(forKey: token)
        }
        if !expired.isEmpty {
            Self.logger.info("Pruned \(expired.count) expired token(s)")
        }
    }
}
