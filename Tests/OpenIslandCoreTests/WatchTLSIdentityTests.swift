import Testing
import Foundation
import CryptoKit
@testable import OpenIslandCore

/// C-3 cert generation + persistence behavior. Each test runs
/// against a tmp-scoped support directory so the production cert
/// at `~/Library/Application Support/OpenIsland/tls/` is never
/// touched. openssl(1) ships with macOS so these tests run in CI
/// without extra setup.
@Suite struct WatchTLSIdentityTests {

    private func makeBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-tls-\(UUID().uuidString)", isDirectory: true)
    }

    @Test
    func loadOrCreateProducesValidIdentityWithSHA256Fingerprint() throws {
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)

        // SHA-256 hex string is 64 characters (uppercase, no separators).
        #expect(result.fingerprint.count == 64)
        #expect(result.fingerprint.allSatisfy { c in
            ("0"..."9").contains(c) || ("A"..."F").contains(c)
        })

        // Identity must yield a valid certificate.
        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(result.identity, &certRef)
        #expect(status == errSecSuccess)
        #expect(certRef != nil)
    }

    @Test
    func loadOrCreateIsIdempotent() throws {
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)
        let second = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)
        // Second call must reuse the persisted identity, not
        // regenerate a new one with a different fingerprint.
        #expect(first.fingerprint == second.fingerprint)
    }

    @Test
    func resetForcesRegeneration() throws {
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)
        try WatchTLSIdentity.reset(baseSupportURL: base)
        let second = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)
        // After reset the new identity is a fresh keypair —
        // fingerprint must differ.
        #expect(first.fingerprint != second.fingerprint)
    }

    @Test
    func directoryHasOwnerOnlyPermissions() throws {
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)

        let dir = WatchTLSIdentity.directoryURL(baseSupportURL: base)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect(posix?.intValue == 0o700)
    }

    @Test
    func persistedFilesHaveOwnerOnlyPermissions() throws {
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)

        let dir = WatchTLSIdentity.directoryURL(baseSupportURL: base)
        for filename in [
            WatchTLSIdentity.identityFileName,
            WatchTLSIdentity.metadataFileName,
            "watch-key.pem",
            "watch-cert.pem",
        ] {
            let url = dir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let posix = attrs[.posixPermissions] as? NSNumber
            #expect(posix?.intValue == 0o600, "\(filename) must be 0o600")
        }
    }

    @Test
    func fingerprintMatchesOpenSSLCalculation() throws {
        // Cross-check our SHA-256 fingerprint with what
        // openssl(1) would print, so we know clients pinning the
        // value via TXT record can recompute it from the wire
        // certificate.
        let base = makeBaseURL()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try WatchTLSIdentity.loadOrCreate(baseSupportURL: base)

        var certRef: SecCertificate?
        _ = SecIdentityCopyCertificate(result.identity, &certRef)
        let der = SecCertificateCopyData(certRef!) as Data
        let computed = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        #expect(result.fingerprint == computed)
    }
}
