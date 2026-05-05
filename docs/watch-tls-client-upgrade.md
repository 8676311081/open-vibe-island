# Watch TLS Client Upgrade Spec (audit C-3 / M-1 / M-2)

**Status**: server-side complete (Phase 3A landed). iOS / watchOS clients still emit cleartext + no nonce. This doc tells the next person sitting at Xcode exactly what to change.

**Why this is a doc, not code**: iOS/watchOS targets don't compile under SwiftPM, so they can't be exercised from `swift test`. Touching them requires Xcode + a real device (or a paired simulator pair) for a meaningful round-trip. Doing that at 3 a.m. would have meant blind diffs against `ios/OpenIslandMobile/` that nobody could verify until morning anyway.

---

## What the server now offers

After Phase 3A, `WatchHTTPEndpoint` exposes **two listeners**, advertised through one Bonjour service (`_openisland._tcp`):

| Listener | Port | Bonjour TXT signal | Purpose |
|---|---|---|---|
| Cleartext (legacy) | service's primary port | implicit | Backward-compat for any in-the-wild watch app build |
| TLS (preferred) | published in TXT `tls-port=<port>` | `tls=1`, `cert-fp=<sha256-uppercase-hex>` | New clients pin the fingerprint |

Additional TXT keys:

| Key | Value | Meaning |
|---|---|---|
| `proto-version` | `1` | Bumps when wire format changes; refuse server if number unknown. |
| `nonce-required` | `1` | Mutating endpoints (`/pair`, `/resolution`) accept `X-OI-Nonce` + `X-OI-Timestamp`. Soft-enforced on the server today; hard-enforced in a follow-up commit once all shipped clients are upgraded. |

Cert fingerprint format: SHA-256 over the DER-encoded certificate, **uppercase hex with no separators**, 64 chars. Validate exactly that shape — clients sometimes drift to lowercase or colon-separated and the server's pin won't match.

---

## What the iOS / watchOS client must change

Two files do the network plumbing:

- `ios/OpenIslandMobile/Network/BonjourDiscovery.swift` — finds `_openisland._tcp` on the LAN.
- `ios/OpenIslandMobile/Network/ConnectionManager.swift` — opens the actual TCP/HTTP connection per pairing/SSE/POST flow.

The watch app reaches the server through the iOS companion via `ios/OpenIslandWatch/WatchSessionManager.swift`, which passes through to the same `ConnectionManager` paths. No additional networking code path on watchOS — once iOS is upgraded, the watch follows for free.

### Step 1: parse the new TXT record fields in `BonjourDiscovery.swift`

Today `DiscoveredMac` only records `id`, `name`, `endpoint`. Add:

```swift
struct DiscoveredMac: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    /// SHA-256 of the server's TLS cert, UPPERCASE hex, no separators.
    /// `nil` when the server didn't advertise `tls=1` (legacy
    /// cleartext-only).
    let tlsFingerprint: String?
    /// Port to use for TLS connections. Falls back to the
    /// service's main port when `tlsFingerprint == nil`.
    let tlsPort: NWEndpoint.Port?
    /// True when the server advertises `nonce-required=1`.
    /// Treat as the floor for this client too — start sending
    /// nonces unconditionally regardless of the flag, but record
    /// it so a future hard-enforce check can reject downgrade
    /// attacks.
    let serverRequiresNonce: Bool
}
```

`NWBrowser.Result` carries metadata on `.metadata` of type `NWBrowser.Result.Metadata`. For Bonjour services the case is `.bonjour(let txt)` where `txt` is `NWTXTRecord`. Read with:

```swift
guard case let .bonjour(txt) = result.metadata else { return /* legacy server */ }
let tlsFingerprint = (txt["tls"] == "1") ? txt["cert-fp"] : nil
let tlsPort = (txt["tls-port"]).flatMap(UInt16.init).flatMap(NWEndpoint.Port.init)
let serverRequiresNonce = (txt["nonce-required"] == "1")
```

### Step 2: open a TLS connection in `ConnectionManager.swift`

Today the manager builds an HTTP URL and uses `URLSession` (in places) or `NWConnection(to: endpoint, using: .tcp)`. Replace the connection construction:

```swift
private func makeConnection(to mac: DiscoveredMac) -> NWConnection {
    if let fingerprint = mac.tlsFingerprint, let port = mac.tlsPort {
        return makeTLSConnection(host: mac.endpoint, tlsPort: port, expectedFingerprint: fingerprint)
    }
    // Legacy cleartext fallback (no upgrade signal).
    return NWConnection(to: mac.endpoint, using: .tcp)
}

private func makeTLSConnection(
    host: NWEndpoint, tlsPort: NWEndpoint.Port, expectedFingerprint: String
) -> NWConnection {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(
        tls.securityProtocolOptions, .TLSv12)

    // Disable Apple's default trust evaluation — our cert is
    // self-signed and not in any chain. Validate via fingerprint
    // pinning instead.
    sec_protocol_options_set_verify_block(
        tls.securityProtocolOptions,
        { _, sec_trust, completion in
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first
            else { completion(false); return }
            let der = SecCertificateCopyData(leaf) as Data
            let digest = SHA256.hash(data: der)
            let actual = digest.map { String(format: "%02X", $0) }.joined()
            completion(actual == expectedFingerprint)
        },
        DispatchQueue.global(qos: .userInitiated))

    let params = NWParameters(tls: tls)
    // The host is from Bonjour — already an .service or .hostPort
    // endpoint. We need the same host + the TLS-specific port. If
    // the discovered endpoint is .service, Network framework
    // resolves the port automatically; we override with the TXT
    // tls-port when present.
    let target: NWEndpoint
    if case .service(let n, let t, let d, _) = host {
        target = .service(name: n, type: t, domain: d, interface: nil)
        // To force the TLS port we'd actually need to resolve the
        // service ourselves and re-construct as .hostPort — see
        // notes below.
    } else {
        target = host
    }
    return NWConnection(to: target, using: params)
}
```

### Step 3: send nonce headers on every mutating request

For `POST /pair`, `POST /resolution`:

```swift
request.setValue(UUID().uuidString, forHTTPHeaderField: "X-OI-Nonce")
request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-OI-Timestamp")
```

The nonce just needs to be unique per request — UUID is sufficient (122 random bits >> server's 600s retention window).

The timestamp must be within ±300 seconds of the server's wall clock. iOS clocks are accurate to ~seconds via NTP; this margin is generous.

### Step 4: change the URL scheme

URLs in `ConnectionManager.swift` lines ~292 and ~535 currently say `http://...`. When `mac.tlsFingerprint != nil`, switch to `https://...`. Also use `mac.tlsPort` instead of the service's primary port.

### Step 5: persist the fingerprint per-paired-Mac

Once the user has paired with a Mac (`POST /pair` succeeded), save `mac.tlsFingerprint` to user defaults keyed by the Mac's stable id. On future connections to the same Mac, refuse to fall back to cleartext even if the server starts advertising `tls=0` — that prevents a downgrade attack on a known-TLS-capable Mac.

---

## Local test plan

1. Run the macOS app from this PR (it already brings up both listeners).
2. Look at Console.app, filter `subsystem:app.openisland category:WatchHTTPEndpoint`. You should see two `listener ready` lines, one for cleartext and one for TLS, plus the cert fingerprint.
3. From a terminal, verify the TLS listener accepts handshakes:

   ```bash
   PORT=$(dns-sd -B _openisland._tcp local. &  # or use Bonjour Browser.app)
   openssl s_client -connect 127.0.0.1:$TLS_PORT -showcerts < /dev/null
   ```

   Compare the printed `subject=CN=Open Island Watch Endpoint` and the SHA-256 fingerprint to what's in the TXT record.

4. Run the iOS app from Xcode (still cleartext, since client upgrade isn't done yet). Pairing should still work — that's the dual-stack guarantee.

5. After the client upgrade ships, re-run pairing on the same iPhone with a fresh install. Confirm Console shows the iPhone hitting the TLS port. Wireshark on the LAN interface should show only encrypted traffic to/from the new port.

6. Replay protection check: capture a `POST /pair` on the wire (clear or TLS-decrypted), modify nothing, replay it five seconds later. Expect `409 Conflict` from the server.

---

## Out of scope for this milestone

- **Mutual TLS** — pinning is one-way (client verifies server). Server-verifies-client would require a second cert distribution step at pairing time. Not necessary for the threat model (the bearer token already authenticates the client to the server) but a future hardening option.
- **Hard-enforce nonce on legacy cleartext clients** — once Apple-Connect tells us no installs older than the upgraded client are still using the service, flip the soft-enforce flag. Until then a connection with no nonce headers gets through.
- **Cert rotation UX** — currently `WatchTLSIdentity.reset()` exists but isn't exposed in Settings. Add a "Reset Watch Pairing" button that calls it + invalidates all paired tokens.

---

## Audit row updates after this milestone

| Audit ID | Pre | Post |
|---|---|---|
| C-3 (Watch TLS) | unmitigated | server-side complete; client upgrade scheduled |
| M-1 (Watch token replay) | unmitigated | server enforces if client opts in; soft-enforce by default |
| M-2 (`/resolution` no replay protection) | unmitigated | same nonce gate covers it |
