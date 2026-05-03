import Foundation
import Testing
@testable import OpenIslandCore

// MARK: - In-memory cookie store

struct ClaudeWebUsageCookieStoreTests {
    @Test
    func saveLoadDeleteRoundTrip() throws {
        let store = InMemoryClaudeWebUsageCookieStore()
        #expect(try store.loadCookie() == nil)
        try store.saveCookie("session=abc123")
        #expect(try store.loadCookie() == "session=abc123")
        try store.deleteCookie()
        #expect(try store.loadCookie() == nil)
    }

    @Test
    func saveTrimsWhitespaceAndRejectsEmpty() throws {
        let store = InMemoryClaudeWebUsageCookieStore()
        try store.saveCookie("  hello\n")
        #expect(try store.loadCookie() == "hello")

        do {
            try store.saveCookie("   ")
            #expect(Bool(false), "expected throw on whitespace-only cookie")
        } catch let error as ClaudeWebUsageCookieStoreError {
            #expect(error == .invalidCookie)
        }
    }
}

// MARK: - URLProtocol mock

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMockClient(_ responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> ClaudeWebUsageClient {
    MockURLProtocol.responder = responder
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeWebUsageClient(session: session, baseURL: URL(string: "https://claude.ai")!)
}

private func httpResponse(url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

// MARK: - Client

@Suite(.serialized)
struct ClaudeWebUsageClientTests {
    @Test
    func fetchOrganizationsParsesUUIDList() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.path == "/api/organizations")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sk=abc")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OpenIsland/") == true)
            let body = """
            [
              {"uuid":"org-1","role":"admin","name":"Default"},
              {"uuid":"org-2","role":"pending","name":"Pending Invite"}
            ]
            """.data(using: .utf8)!
            return (httpResponse(url: request.url!, status: 200), body)
        }

        let orgs = try await client.fetchOrganizations(cookie: "sk=abc")
        #expect(orgs.count == 2)
        #expect(orgs[0].id == "org-1")
        #expect(orgs[0].role == "admin")
        #expect(orgs[1].role == "pending")
    }

    @Test
    func fetchOrganizationsRejectsEmptyResponse() async throws {
        let client = makeMockClient { request in
            (httpResponse(url: request.url!, status: 200), Data("[]".utf8))
        }

        do {
            _ = try await client.fetchOrganizations(cookie: "sk=abc")
            #expect(Bool(false), "expected schemaMismatch for empty array")
        } catch let error as ClaudeWebUsageClientError {
            if case .schemaMismatch = error {
                // ok
            } else {
                #expect(Bool(false), "expected schemaMismatch, got \(error)")
            }
        }
    }

    @Test
    func fetchUsageRawReturnsBodyWhenSchemaIntact() async throws {
        let payload = #"{"five_hour":{"utilization":40,"resets_at":"2026-05-03T15:10:00Z"},"seven_day":{"utilization":47,"resets_at":"2026-05-07T09:00:00Z"}}"#
        let client = makeMockClient { request in
            #expect(request.url?.path == "/api/organizations/org-1/usage")
            return (httpResponse(url: request.url!, status: 200), Data(payload.utf8))
        }

        let raw = try await client.fetchUsageRaw(cookie: "sk=abc", organizationID: "org-1")
        #expect(String(data: raw, encoding: .utf8) == payload)
    }

    @Test
    func fetchUsageRawSchemaMismatchOnUnexpectedShape() async throws {
        let client = makeMockClient { request in
            (httpResponse(url: request.url!, status: 200), Data(#"{"hello":"world"}"#.utf8))
        }

        do {
            _ = try await client.fetchUsageRaw(cookie: "sk=abc", organizationID: "org-1")
            #expect(Bool(false))
        } catch let error as ClaudeWebUsageClientError {
            if case .schemaMismatch = error {
                // ok
            } else {
                #expect(Bool(false), "expected schemaMismatch, got \(error)")
            }
        }
    }

    @Test
    func unauthorizedMappingFor401And403() async throws {
        for status in [401, 403] {
            let client = makeMockClient { request in
                (httpResponse(url: request.url!, status: status), Data())
            }
            do {
                _ = try await client.fetchUsageRaw(cookie: "sk=abc", organizationID: "org-1")
                #expect(Bool(false))
            } catch let error as ClaudeWebUsageClientError {
                #expect(error == .unauthorized, "status \(status) should map to unauthorized")
            }
        }
    }

    @Test
    func rateLimitedExtractsRetryAfter() async throws {
        let client = makeMockClient { request in
            (httpResponse(url: request.url!, status: 429, headers: ["Retry-After": "30"]), Data())
        }
        do {
            _ = try await client.fetchUsageRaw(cookie: "sk=abc", organizationID: "org-1")
            #expect(Bool(false))
        } catch let error as ClaudeWebUsageClientError {
            if case let .rateLimited(retryAfter) = error {
                #expect(retryAfter == 30)
            } else {
                #expect(Bool(false), "expected rateLimited, got \(error)")
            }
        }
    }

    @Test
    func missingCookieFailsBeforeNetwork() async throws {
        let client = makeMockClient { _ in
            #expect(Bool(false), "no network call should happen")
            return (httpResponse(url: URL(string: "https://x")!, status: 200), Data())
        }
        do {
            _ = try await client.fetchUsageRaw(cookie: "   ", organizationID: "org-1")
            #expect(Bool(false))
        } catch let error as ClaudeWebUsageClientError {
            #expect(error == .missingCookie)
        }
    }
}

// MARK: - Poller

private final class IntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class StubFetcher: ClaudeWebUsageFetching, @unchecked Sendable {
    var organizations: Result<[ClaudeWebOrganization], Error> = .success([
        ClaudeWebOrganization(id: "org-1", role: "admin", name: "Default"),
    ])
    var usage: Result<Data, Error> = .success(Data(#"{"five_hour":{"utilization":12}}"#.utf8))
    private(set) var fetchUsageCount = 0

    func fetchOrganizations(cookie: String) async throws -> [ClaudeWebOrganization] {
        try organizations.get()
    }

    func fetchUsageRaw(cookie: String, organizationID: String) async throws -> Data {
        fetchUsageCount += 1
        return try usage.get()
    }
}

struct ClaudeWebUsagePollerTests {
    @Test
    func successfulRefreshWritesCacheAndResolvesOrgID() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-poller-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cacheURL = tmpDir.appendingPathComponent("rl.json")

        let fetcher = StubFetcher()
        let cookieStore = InMemoryClaudeWebUsageCookieStore(initialCookie: "sk=abc")
        let poller = ClaudeWebUsagePoller(client: fetcher, cookieStore: cookieStore, cacheURL: cacheURL)

        await poller.refreshNow()

        let written = try Data(contentsOf: cacheURL)
        #expect(String(data: written, encoding: .utf8) == #"{"five_hour":{"utilization":12}}"#)

        let state = poller.currentState
        #expect(state.lastSuccessAt != nil)
        #expect(state.consecutiveFailures == 0)
        #expect(state.resolvedOrganizationID == "org-1")
    }

    @Test
    func unauthorizedFiresOnAuthFailureAndKeepsCacheUntouched() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-poller-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cacheURL = tmpDir.appendingPathComponent("rl.json")
        try Data("{\"existing\":\"untouched\"}".utf8).write(to: cacheURL)

        let fetcher = StubFetcher()
        fetcher.usage = .failure(ClaudeWebUsageClientError.unauthorized)
        let cookieStore = InMemoryClaudeWebUsageCookieStore(initialCookie: "sk=abc")
        let poller = ClaudeWebUsagePoller(client: fetcher, cookieStore: cookieStore, cacheURL: cacheURL)

        let authFired = IntCounter()
        poller.onAuthFailure = { authFired.increment() }

        await poller.refreshNow()

        #expect(authFired.get() == 1)
        let after = try Data(contentsOf: cacheURL)
        #expect(String(data: after, encoding: .utf8) == "{\"existing\":\"untouched\"}")

        let state = poller.currentState
        #expect(state.consecutiveFailures == 1)
        #expect(state.lastErrorMessage?.contains("expired") == true || state.lastErrorMessage?.contains("rejected") == true)
    }

    @Test
    func consecutiveFailuresCrossingTenFiresSchemaDriftOnce() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-poller-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cacheURL = tmpDir.appendingPathComponent("rl.json")

        let fetcher = StubFetcher()
        fetcher.usage = .failure(ClaudeWebUsageClientError.schemaMismatch(reason: "test"))
        let cookieStore = InMemoryClaudeWebUsageCookieStore(initialCookie: "sk=abc")
        let poller = ClaudeWebUsagePoller(client: fetcher, cookieStore: cookieStore, cacheURL: cacheURL)

        let driftCount = IntCounter()
        poller.onSchemaDrift = { driftCount.increment() }

        for _ in 0..<12 {
            await poller.refreshNow()
        }

        let state = poller.currentState
        #expect(state.consecutiveFailures == 12)
        #expect(state.driftSuspected == true)
        #expect(driftCount.get() == 1, "drift callback should fire exactly once at the threshold")
    }

    @Test
    func missingCookieFailsWithoutCallingClient() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-poller-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cacheURL = tmpDir.appendingPathComponent("rl.json")

        let fetcher = StubFetcher()
        let cookieStore = InMemoryClaudeWebUsageCookieStore() // no cookie
        let poller = ClaudeWebUsagePoller(client: fetcher, cookieStore: cookieStore, cacheURL: cacheURL)

        await poller.refreshNow()

        #expect(fetcher.fetchUsageCount == 0)
        #expect(poller.currentState.consecutiveFailures == 1)
    }
}
