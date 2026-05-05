import Testing
import Foundation
@testable import OpenIslandCore

/// H-6: cross-process advisory lock primitive used by every
/// installer that mutates a shared user-config file. These tests
/// exercise both the happy path (uncontended) and the contention
/// path (timeout).
@Suite struct SettingsFileLockTests {

    private func makeLockURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-h6-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("install.lock")
    }

    @Test
    func uncontendedAcquireRunsBodyAndReleases() throws {
        let lock = makeLockURL("uncontended")
        defer { try? FileManager.default.removeItem(at: lock.deletingLastPathComponent()) }

        var ran = false
        let result = try SettingsFileLock.withLock(at: lock) {
            ran = true
            return 42
        }
        #expect(ran)
        #expect(result == 42)

        // Lock file persists after release (fd-scoped flock semantics).
        #expect(FileManager.default.fileExists(atPath: lock.path))

        // Re-acquiring after release succeeds (proves prior unlock).
        let secondResult = try SettingsFileLock.withLock(at: lock) { 99 }
        #expect(secondResult == 99)
    }

    @Test
    func bodyErrorReleasesLock() throws {
        let lock = makeLockURL("body-error")
        defer { try? FileManager.default.removeItem(at: lock.deletingLastPathComponent()) }

        struct ToyError: Error {}
        do {
            _ = try SettingsFileLock.withLock(at: lock) {
                throw ToyError()
            }
            Issue.record("withLock should have rethrown the body's error")
        } catch is ToyError {
            // expected
        }
        // Lock must be released — second acquire succeeds without
        // hitting the timeout.
        let secondResult = try SettingsFileLock.withLock(at: lock, timeout: 1.0) { "ok" }
        #expect(secondResult == "ok")
    }

    @Test
    func contentionTimesOutWithLockContentionError() async throws {
        let lock = makeLockURL("contention")
        defer { try? FileManager.default.removeItem(at: lock.deletingLastPathComponent()) }

        // Hold the lock from one task while another task tries to
        // acquire with a short timeout.
        let holderEntered = AsyncSemaphore()
        let holderShouldRelease = AsyncSemaphore()

        let holderTask = Task {
            try SettingsFileLock.withLock(at: lock) {
                Task { await holderEntered.signal() }
                // Block the holder synchronously until the contender
                // has finished hitting its timeout, but in a way that
                // can observe the actor-bound signal.
                let group = DispatchGroup()
                group.enter()
                Task {
                    await holderShouldRelease.wait()
                    group.leave()
                }
                _ = group.wait(timeout: .now() + .seconds(10))
            }
        }

        await holderEntered.wait()

        // Contender: 0.3 s timeout — fast enough to keep the test
        // snappy, long enough to swallow normal CI jitter.
        let start = Date()
        do {
            _ = try SettingsFileLock.withLock(at: lock, timeout: 0.3) { 0 }
            Issue.record("contender should have timed out")
        } catch let error as SettingsFileLockError {
            switch error {
            case .lockContention(let url):
                #expect(url.path == lock.path)
            case .lockSystemError:
                Issue.record("expected .lockContention but got system error")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        // Should be roughly 0.3 s, allow generous slack on CI.
        #expect(elapsed >= 0.25)
        #expect(elapsed < 1.5)

        await holderShouldRelease.signal()
        try await holderTask.value
    }

    @Test
    func parentDirectoryCreatedOnDemand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openisland-h6-mkdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Deeply-nested non-existent path.
        let lock = root
            .appendingPathComponent("deeper")
            .appendingPathComponent("nested")
            .appendingPathComponent("install.lock")

        // No pre-creation of the parent.
        #expect(!FileManager.default.fileExists(atPath: lock.deletingLastPathComponent().path))

        try SettingsFileLock.withLock(at: lock) { /* no-op */ }

        // Parent + lock file both exist after the call.
        #expect(FileManager.default.fileExists(atPath: lock.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }
}

// MARK: - Test helper

/// Minimal async semaphore. Avoids pulling in extra deps; the lock
/// test needs a way to signal across structured-concurrency tasks
/// that DispatchSemaphore can't deliver without busy-waiting.
private actor AsyncSemaphore {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { c in pending.append(c) }
    }

    func signal() {
        signaled = true
        let waiters = pending
        pending.removeAll()
        for c in waiters { c.resume() }
    }
}
