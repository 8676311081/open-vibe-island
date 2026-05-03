import Foundation
import Testing
@testable import OpenIslandCore

/// Local stub backend so rewriter tests don't reach the real
/// Keychain. Mirrors the InMemory pattern in
/// `RouterCredentialsStoreTests` but stays file-private — these
/// tests don't share state with that suite.
private final class StubCredentialsBackend: RouterCredentialsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func setCredential(_ value: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }
    func credential(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }
    func deleteCredential(for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
    func listAccounts() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}

private func makeStore(_ storedKeys: [String: String] = [:]) -> RouterCredentialsStore {
    let backend = StubCredentialsBackend()
    for (k, v) in storedKeys {
        try? backend.setCredential(v, for: k)
    }
    return RouterCredentialsStore(backend: backend)
}

/// Resolver wired to the built-in profile set with isolated
/// UserDefaults so tests don't interfere with each other or with
/// real app state. Sufficient for header-rewriter tests: the
/// rewriter doesn't care which profile resolves, only whether the
/// matched profile has a `keychainAccount` set.
private func makeBuiltinResolver() -> any UpstreamProfileResolver {
    let suite = "rewriter-test-\(UUID().uuidString)"
    return UpstreamProfileStore(userDefaults: UserDefaults(suiteName: suite)!)
}

/// Suite name disambiguated from `LLMRequestRewriterTests` (which
/// already lives in `LLMUsageHeuristicsTests.swift` and covers the
/// body-rewrite path for OpenAI streaming). Header-rewrite is a
/// separate audit-list entry — keep the test surface separate so a
/// failure here points straight at the right policy item.
struct LLMRequestRewriterAuthorizationTests {
    // MARK: - Authorization rewrite

    @Test
    func authorizationPassthroughWhenUpstreamIsAnthropicNative() {
        // Even with a DeepSeek key in the store, an Anthropic-bound
        // request must keep the user's original Anthropic Bearer.
        // Otherwise we'd send DSV4 keys to api.anthropic.com.
        let store = makeStore(["deepseek": "sk-DSV4-secret"])
        var headers: [(name: String, value: String)] = [
            (name: "Authorization", value: "Bearer sk-ant-USER-KEY"),
            (name: "Content-Type", value: "application/json"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        let auth = headers.first(where: { $0.name.lowercased() == "authorization" })?.value
        #expect(auth == "Bearer sk-ant-USER-KEY")
        // Other headers must be preserved.
        #expect(headers.contains(where: { $0.name == "Content-Type" }))
    }

    @Test
    func authorizationReplacedWhenUpstreamIsDeepSeekAndKeyStored() {
        let store = makeStore(["deepseek": "sk-DSV4-secret"])
        var headers: [(name: String, value: String)] = [
            (name: "Authorization", value: "Bearer sk-ant-WRONG"),
            (name: "X-Other", value: "preserved"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        let auth = headers.first(where: { $0.name.lowercased() == "authorization" })?.value
        #expect(auth == "Bearer sk-DSV4-secret")
        #expect(headers.contains(where: { $0.name == "X-Other" && $0.value == "preserved" }))
    }

    @Test
    func authorizationPassthroughWhenUpstreamIsDeepSeekButKeyMissing() {
        // Fail-open: an upstream-side 401 is the loud signal we want.
        // Silently sending an empty Bearer would mask the
        // misconfiguration and confuse user debugging.
        let store = makeStore() // no DeepSeek key
        var headers: [(name: String, value: String)] = [
            (name: "Authorization", value: "Bearer sk-ant-USER"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        #expect(headers.first?.value == "Bearer sk-ant-USER")
    }

    @Test
    func authorizationCaseInsensitiveHeaderName() {
        // HTTP header names are case-insensitive. Two case-variant
        // entries must collapse to a single override (sending two
        // distinct credentials would confuse the upstream).
        let store = makeStore(["deepseek": "sk-X"])
        var headers: [(name: String, value: String)] = [
            (name: "authorization", value: "Bearer original-1"),
            (name: "AUTHORIZATION", value: "Bearer original-2"),
            (name: "X-Trace", value: "abc"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.deepseek.com/anthropic")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        let authHeaders = headers.filter { $0.name.lowercased() == "authorization" }
        #expect(authHeaders.count == 1, "case-variant Authorization headers should collapse to one")
        #expect(authHeaders.first?.value == "Bearer sk-X")
        // Non-Authorization headers preserved.
        #expect(headers.contains(where: { $0.name == "X-Trace" && $0.value == "abc" }))
    }

    @Test
    func authorizationAppendedWhenAbsentAndUpstreamIsDeepSeek() {
        // Edge case: client didn't send Authorization at all (rare but
        // possible). When the upstream needs one, we append rather
        // than silently sending an unauthenticated request.
        let store = makeStore(["deepseek": "sk-Y"])
        var headers: [(name: String, value: String)] = [
            (name: "Content-Type", value: "application/json"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.deepseek.com/anthropic")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        let auth = headers.first(where: { $0.name.lowercased() == "authorization" })?.value
        #expect(auth == "Bearer sk-Y")
    }

    @Test
    func emptyStoredKeyTreatedAsMissing() {
        // Defensive: if Keychain returns an empty string for the
        // provider account (corruption / user typed a blank), we
        // shouldn't actually emit `Authorization: Bearer ` — fail
        // open just like the missing-key case.
        let store = makeStore(["deepseek": ""])
        var headers: [(name: String, value: String)] = [
            (name: "Authorization", value: "Bearer original"),
        ]
        LLMRequestRewriter.rewriteAuthorizationIfNeeded(
            &headers,
            upstreamURL: URL(string: "https://api.deepseek.com/anthropic")!,
            profileResolver: makeBuiltinResolver(),
            credentialsStore: store
        )
        #expect(headers.first?.value == "Bearer original")
    }
}
