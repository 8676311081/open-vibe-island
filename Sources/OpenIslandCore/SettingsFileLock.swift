import Foundation
import Darwin

/// Errors raised by the cross-process advisory file lock used to
/// serialize concurrent installer/mutator processes. Distinct from
/// per-installer error types so callers can match on the lock failure
/// independently of any other error their flow might raise.
public enum SettingsFileLockError: LocalizedError, Sendable {
    /// `flock(LOCK_EX | LOCK_NB)` returned EWOULDBLOCK past the timeout
    /// deadline. Implies another OpenIsland instance — or a user-edited
    /// process holding the same lock file — is wedged.
    case lockContention(URL)
    /// `open(2)` or `flock(2)` returned a non-recoverable errno (not
    /// EWOULDBLOCK). The captured value is the raw errno at the failure
    /// site.
    case lockSystemError(URL, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .lockContention(let url):
            return "Timed out waiting for advisory lock at \(url.path); another installer may be stuck."
        case let .lockSystemError(url, errnoValue):
            return "Failed to acquire advisory lock at \(url.path) (errno=\(errnoValue))."
        }
    }
}

/// Cross-process advisory `flock(2)` helper. Used by every component
/// that mutates a shared user-config JSON / TOML file (Claude Code,
/// Codex, Cursor, Gemini) so two OpenIsland processes — or
/// OpenIsland racing the user's text editor — can't trample each
/// other's writes.
///
/// **Usage:**
/// ```swift
/// try SettingsFileLock.withLock(at: dir.appendingPathComponent("install.lock")) {
///     // mutate settings.json / hooks.json / etc.
/// }
/// ```
///
/// Lock file is created on first use (`O_CREAT`) and intentionally
/// left on disk after release: flock is fd-scoped (released on
/// close), so file persistence is harmless and lets concurrent
/// processes share a single inode without coordination tricks.
///
/// flock has no native blocking-with-timeout, so we poll
/// `LOCK_EX | LOCK_NB` with a 50 ms backoff until the deadline.
/// Polling is acceptable because contention is rare in practice
/// (only when two install flows fire simultaneously).
public enum SettingsFileLock {
    /// Reasonable default for installer / mutator paths. 30 s is
    /// long enough to swallow IO stalls and short enough that a
    /// genuinely deadlocked peer surfaces as an actionable error
    /// rather than a hung UI.
    public static let defaultTimeout: TimeInterval = 30

    /// Acquire an exclusive flock on `lockFileURL`, run `body`, then
    /// release the lock. Creates parent directories on demand.
    ///
    /// `defer` order matters: `close(fd)` is registered FIRST so
    /// LIFO unwinding runs `flock(_, LOCK_UN)` first and `close(fd)`
    /// second. Reversing the order would close the fd while the lock
    /// is still nominally held; macOS auto-releases on close, but
    /// the explicit unlock-then-close sequence is what tools and
    /// debuggers expect.
    public static func withLock<T>(
        at lockFileURL: URL,
        timeout: TimeInterval = defaultTimeout,
        fileManager: FileManager = .default,
        _ body: () throws -> T
    ) throws -> T {
        try fileManager.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = lockFileURL.path.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        guard fd >= 0 else {
            throw SettingsFileLockError.lockSystemError(lockFileURL, errno: errno)
        }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err != EWOULDBLOCK {
                throw SettingsFileLockError.lockSystemError(lockFileURL, errno: err)
            }
            if Date() >= deadline {
                throw SettingsFileLockError.lockContention(lockFileURL)
            }
            usleep(50_000)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }
}
