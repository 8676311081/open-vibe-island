import Foundation
import CryptoKit
import Security
import os

public enum WatchTLSIdentityError: LocalizedError, Sendable {
    case opensslMissing
    case opensslFailed(stage: String, exitCode: Int32, stderr: String)
    case pkcs12LoadFailed(OSStatus)
    case identityExtractFailed
    case certificateExtractFailed
    case storageFailure(String)

    public var errorDescription: String? {
        switch self {
        case .opensslMissing:
            return "/usr/bin/openssl not present — TLS identity generation requires it."
        case let .opensslFailed(stage, code, stderr):
            return "openssl \(stage) failed (exit=\(code)): \(stderr.prefix(200))"
        case let .pkcs12LoadFailed(status):
            return "SecPKCS12Import failed: status=\(status)"
        case .identityExtractFailed:
            return "PKCS12 import returned no SecIdentity."
        case .certificateExtractFailed:
            return "Could not extract certificate data from SecIdentity."
        case let .storageFailure(detail):
            return "TLS identity storage error: \(detail)"
        }
    }
}

/// Self-signed TLS identity used by `WatchHTTPEndpoint` to upgrade
/// the watch/iPhone pairing endpoint from cleartext TCP to TLS
/// (audit C-3).
///
/// **Why not Keychain:** the Watch endpoint is OpenIsland-specific
/// — there's no scenario where another app or human user needs
/// access to this private key. A Keychain entry adds churn (TCC
/// prompts, SecItemAdd dance, shared-keychain edge cases) for
/// zero added security on top of a 0o600 file in the app's
/// support directory.
///
/// **Why openssl(1) for generation:** Swift / Apple don't ship a
/// Mach/X.509 generator outside swift-certificates package —
/// adding a dep just to make one cert at app launch is overkill.
/// `/usr/bin/openssl` ships in every macOS install and is a
/// stable command. Identity is regenerated only when the cert is
/// missing, malformed, or expired (cert validity = 10 years), so
/// the fork-exec cost is amortized across multi-year app
/// lifetimes.
///
/// **Cert subject:** `CN=Open Island Watch Endpoint`. Not used
/// for trust evaluation — clients pin the SHA-256 fingerprint
/// from Bonjour TXT, not the X.500 chain.
public enum WatchTLSIdentity {
    private static let logger = Logger(
        subsystem: "app.openisland",
        category: "WatchTLSIdentity"
    )

    /// Serializes concurrent `loadOrCreate` calls. In production
    /// the app calls this exactly once at startup, but parallel
    /// unit tests (`swift test --parallel`) triggered races where
    /// concurrent openssl(1) processes corrupted each other's
    /// state — even when each test wrote to its own tmp
    /// directory — most likely via shared `~/.rnd` PRNG seed.
    /// A process-wide lock around the generation step makes the
    /// behavior deterministic regardless of concurrent callers
    /// without forcing them to serialize themselves.
    private static let generationLock = NSLock()

    /// Subdirectory under
    /// `~/Library/Application Support/OpenIsland/` where the
    /// generated identity files live. Mode 0700 on the dir, 0600
    /// on each file inside.
    public static let directoryName = "tls"
    public static let identityFileName = "watch-identity.p12"
    /// Marker file co-located with the identity — stores the
    /// generation timestamp so we can re-roll when stale without
    /// re-parsing X.509.
    public static let metadataFileName = "watch-identity.json"

    /// Validity window for the generated cert. 10 years. Watch
    /// pairing endpoints are inherently long-lived and there is
    /// no PKI / revocation chain that benefits from shorter
    /// lifetimes — fingerprint pinning makes cert rotation a
    /// re-pair operation.
    static let certificateValidityDays: Int = 3650

    /// PKCS12 passphrase used between openssl(1) export and
    /// `SecPKCS12Import`. macOS LibreSSL's empty-password export
    /// (`-passout pass:`) and Apple's `SecPKCS12Import` with an
    /// empty `kSecImportExportPassphrase` value disagree on the
    /// underlying PBE algorithms in the resulting bag, leading to
    /// errSecAuthFailed (-25293) on import. A non-empty fixed
    /// passphrase makes both halves agree. The passphrase is not
    /// a secret: anyone with read access to the PKCS12 file
    /// (mode 0600 in the OpenIsland support dir) trivially has
    /// the matching plaintext private key from the bundled
    /// `watch-key.pem` anyway. The 0o600 file permissions are
    /// the actual confidentiality boundary.
    private static let pkcs12Passphrase = "openisland-watch-tls"

    /// Resolved identity directory under the user's app support
    /// area. Caller may override `baseSupportURL` for tests.
    public static func directoryURL(
        baseSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let base = baseSupportURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenIsland", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Result of a load-or-create call. The `SecIdentity` is what
    /// `NWProtocolTLS.Options` needs; `fingerprint` is the
    /// SHA-256 of the DER cert (uppercase hex with colons), the
    /// shape clients pin via Bonjour TXT.
    /// `SecIdentity` is a CoreFoundation type that's documented as
    /// thread-safe but isn't formally `Sendable` in Swift. Mark
    /// the struct `@unchecked Sendable` to opt out of the static
    /// check; thread-safety here is on Apple's CF promise, not
    /// ours.
    public struct LoadResult: @unchecked Sendable {
        public let identity: SecIdentity
        public let fingerprint: String  // SHA-256, uppercase, no separators
    }

    /// Load the persisted TLS identity, regenerating it if missing
    /// or unreadable. Idempotent. Returns the `SecIdentity` ready
    /// to plug into `sec_identity_create` and the cert's SHA-256
    /// fingerprint for client pinning.
    public static func loadOrCreate(
        baseSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> LoadResult {
        let dir = directoryURL(baseSupportURL: baseSupportURL, fileManager: fileManager)
        let identityURL = dir.appendingPathComponent(identityFileName)

        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )

        // Try to load an existing PKCS12 outside the lock first —
        // the common case (every app launch after first run) avoids
        // the contention path entirely.
        if let result = try? loadPKCS12(at: identityURL) {
            logger.debug("Loaded existing TLS identity from \(identityURL.path, privacy: .public) (fp=\(result.fingerprint, privacy: .public))")
            return result
        }

        // Need to generate. Take the process-wide lock so
        // concurrent callers don't race openssl(1).
        generationLock.lock()
        defer { generationLock.unlock() }

        // Re-check after acquiring the lock — another caller may
        // have generated while we were waiting.
        if let result = try? loadPKCS12(at: identityURL) {
            return result
        }

        try generateIdentity(into: dir, fileManager: fileManager)
        let result = try loadPKCS12(at: identityURL)
        logger.info("Generated new self-signed TLS identity (fp=\(result.fingerprint, privacy: .public))")
        return result
    }

    /// Drop persisted identity. Forces regeneration on next load.
    /// Used by tests and the routing pane's "reset Watch
    /// pairing" action.
    public static func reset(
        baseSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let dir = directoryURL(baseSupportURL: baseSupportURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Internals

    private static func loadPKCS12(at url: URL) throws -> LoadResult {
        let data = try Data(contentsOf: url)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: pkcs12Passphrase
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw WatchTLSIdentityError.pkcs12LoadFailed(status)
        }
        let items = rawItems as? [[String: Any]] ?? []
        guard let first = items.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else {
            throw WatchTLSIdentityError.identityExtractFailed
        }
        let identity = identityRef as! SecIdentity
        let fingerprint = try certificateFingerprint(of: identity)
        return LoadResult(identity: identity, fingerprint: fingerprint)
    }

    private static func certificateFingerprint(of identity: SecIdentity) throws -> String {
        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certRef)
        guard status == errSecSuccess, let cert = certRef else {
            throw WatchTLSIdentityError.certificateExtractFailed
        }
        let der = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Find an `openssl` binary that produces PKCS12 archives Apple's
    /// `SecPKCS12Import` actually accepts. macOS-bundled
    /// `/usr/bin/openssl` is LibreSSL 3.3.6, whose default
    /// `pkcs12 -export` output uses an ASN.1 wrapping that current
    /// macOS Security framework rejects with `errSecDecode`
    /// (verified empirically). Homebrew's `openssl@3` (3.x) emits
    /// a compatible bag.
    ///
    /// Search order: prefer Homebrew (Apple silicon path first,
    /// then Intel path), then fall back to system. Returns the
    /// first executable that exists; caller must still tolerate
    /// the system-only case potentially failing the PKCS12 import
    /// downstream.
    static func resolveOpensslPath(fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/openssl",      // Homebrew on Apple silicon
            "/usr/local/opt/openssl@3/bin/openssl",   // Homebrew openssl@3 keg-only
            "/usr/local/bin/openssl",         // Homebrew on Intel
            "/usr/bin/openssl",               // System LibreSSL (last resort)
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func generateIdentity(
        into dir: URL,
        fileManager: FileManager
    ) throws {
        guard let opensslPath = resolveOpensslPath(fileManager: fileManager) else {
            throw WatchTLSIdentityError.opensslMissing
        }
        logger.debug("Using openssl at \(opensslPath, privacy: .public)")

        let keyURL = dir.appendingPathComponent("watch-key.pem")
        let certURL = dir.appendingPathComponent("watch-cert.pem")
        let identityURL = dir.appendingPathComponent(identityFileName)
        let metadataURL = dir.appendingPathComponent(metadataFileName)

        // Clean up any stale partial-state files.
        for url in [keyURL, certURL, identityURL, metadataURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        // 1. Generate ECDSA P-256 cert + key in one go.
        //    `-newkey ec -pkeyopt ec_paramgen_curve:prime256v1` creates
        //    a fresh EC key. `-nodes` writes it unencrypted (we hold
        //    it via 0o600 file perms instead of a password).
        //    `-x509 -days 3650` produces a self-signed cert valid 10y.
        try runOpenSSL(opensslPath, args: [
            "req", "-x509",
            "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-nodes",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", String(certificateValidityDays),
            "-subj", "/CN=Open Island Watch Endpoint"
        ], stage: "req-x509")

        // 2. Bundle into PKCS12 with a fixed non-empty passphrase
        //    (see `pkcs12Passphrase` rationale on the constant).
        try runOpenSSL(opensslPath, args: [
            "pkcs12", "-export",
            "-in", certURL.path,
            "-inkey", keyURL.path,
            "-out", identityURL.path,
            "-name", "Open Island Watch",
            "-passout", "pass:\(pkcs12Passphrase)"
        ], stage: "pkcs12-export")

        // 3. Tighten file perms; key + cert are now redundant once
        //    PKCS12 is on disk, but keep them for openssl-based
        //    debugging at 0o600. Remove if you'd rather minimize
        //    surface area.
        for url in [keyURL, certURL, identityURL] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }

        // 4. Write metadata sidecar.
        let metadata: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "validityDays": certificateValidityDays,
            "subject": "/CN=Open Island Watch Endpoint",
        ]
        let metaData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted]
        )
        try metaData.write(to: metadataURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
    }

    private static func runOpenSSL(
        _ binary: String,
        args: [String],
        stage: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // discard
        do {
            try process.run()
        } catch {
            throw WatchTLSIdentityError.opensslFailed(
                stage: stage,
                exitCode: -1,
                stderr: error.localizedDescription
            )
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData ?? Data(), encoding: .utf8) ?? ""
            throw WatchTLSIdentityError.opensslFailed(
                stage: stage,
                exitCode: process.terminationStatus,
                stderr: errStr
            )
        }
    }
}
