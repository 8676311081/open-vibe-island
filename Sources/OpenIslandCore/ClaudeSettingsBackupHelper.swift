import Foundation
import Darwin

public enum ClaudeSettingsBackupError: LocalizedError, Sendable {
    case invalidSettingsRoot
    case noBackupFound
    /// flock contention timed out (default 30s). Caller should retry or
    /// surface to user — implies another process / installer is holding
    /// the lock for an unreasonably long time.
    case lockContention
    /// flock / open returned a non-recoverable errno (not EWOULDBLOCK).
    /// The Int32 is the captured errno value at the failure site.
    case lockSystemError(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsRoot:
            return "Claude Code settings.json must contain a top-level object."
        case .noBackupFound:
            return "No Claude settings backup file found."
        case .lockContention:
            return "Timed out waiting for ~/.claude/settings.json.lock; another installer may be stuck."
        case .lockSystemError(let errnoValue):
            return "Failed to acquire ~/.claude/settings.json.lock (errno=\(errnoValue))."
        }
    }
}

/// Single entry-point for mutating `~/.claude/settings.json`.
///
/// Every public mutation API guarantees a timestamped
/// `settings.json.backup.<ISO-8601>` file lands on disk *before* the
/// settings file is rewritten, so callers cannot reach a "modified but
/// not backed up" state without going around this helper.
///
/// Backup naming uses the same hyphenated-ISO-8601 format the rest of
/// the codebase already uses (`2026-05-01T20-53-50Z`). Filenames sort
/// lexically == chronologically, so `listBackups()` simply sorts by
/// filename descending to surface the newest first.
public enum ClaudeSettingsBackupHelper {
    public static let settingsFileName = "settings.json"
    public static let backupExtensionPrefix = "backup."
    /// Sibling lock file used for cross-process serialization of mutate
    /// / write APIs. Created on first use with `O_CREAT`, never deleted
    /// — flock is fd-scoped (released on close), so the file persisting
    /// across runs is harmless and lets us reuse the same inode.
    public static let lockFileName = "settings.json.lock"
    /// Default flock contention deadline. Mutate operations are
    /// expected to take milliseconds; 30 s only fires if another
    /// installer is wedged.
    public static let defaultLockTimeoutSeconds: TimeInterval = 30

    public enum WriteOutcome: Sendable {
        /// Producer determined nothing needed to change. No backup is
        /// taken and the on-disk file is left untouched.
        case noChange
        /// Atomically write these bytes to settings.json.
        case write(Data)
        /// Remove settings.json (if it exists).
        case delete
    }

    // MARK: - Serialization

    /// Serialize a Claude Code settings dict using formatting that
    /// minimizes diff drift against the file Claude Code itself
    /// produces:
    ///
    /// - `.prettyPrinted` (2-space indent, like `JSON.stringify(_, null, 2)`)
    /// - `.withoutEscapingSlashes` so `/` is not rewritten as `\/`
    ///   (Foundation's default does — Claude Code/JS doesn't)
    /// - Post-process to drop the single space Foundation inserts
    ///   *before* every colon (`"key" : v` → `"key": v`)
    ///
    /// **Known limitation:** key order is implementation-defined.
    /// Foundation does not preserve insertion order on Dictionary
    /// serialization, and we deliberately do not pass `.sortedKeys`
    /// because that would alphabetize the user's existing
    /// settings.json on every install. Result: a fresh-from-Claude-Code
    /// settings.json may have keys in a different order after the first
    /// helper-driven write. Subsequent helper-driven writes are
    /// deterministic in the same process and stable across rebuild.
    public static func serializeSettings(_ dict: [String: Any]) throws -> Data {
        let raw = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let str = String(data: raw, encoding: .utf8) else { return raw }
        return Data(normalizeColonSpacing(str).utf8)
    }

    /// Drop the leading space Foundation inserts before every colon in
    /// pretty-printed JSON, but only when the colon is structural
    /// (outside a JSON string). State-machine pass over the bytes to
    /// avoid touching `" : "` that occurs inside a string value.
    static func normalizeColonSpacing(_ s: String) -> String {
        enum State { case outside, inString, inStringEscape }
        var out = ""
        out.reserveCapacity(s.count)
        var state: State = .outside
        for ch in s {
            switch state {
            case .outside:
                if ch == "\"" {
                    state = .inString
                    out.append(ch)
                } else {
                    if ch == ":", out.last == " " {
                        out.removeLast()
                    }
                    out.append(ch)
                }
            case .inString:
                if ch == "\\" {
                    state = .inStringEscape
                } else if ch == "\"" {
                    state = .outside
                }
                out.append(ch)
            case .inStringEscape:
                state = .inString
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Read

    /// Read-only snapshot of `settings.json`. Returns an empty dict when
    /// the file doesn't exist.
    public static func currentSettings(
        directory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default
    ) throws -> [String: Any] {
        let url = settingsURL(directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw ClaudeSettingsBackupError.invalidSettingsRoot
        }
        return dict
    }

    // MARK: - Write (closed APIs — caller cannot bypass backup)

    /// Dict-level mutation. Convenience for callers whose new settings
    /// content is best expressed as `(inout [String: Any]) -> Void`.
    /// Internally serializes with `[.prettyPrinted, .sortedKeys]`.
    ///
    /// Sequence: read existing → backup (if file exists) → run block →
    /// serialize → atomic write. The block runs only after the backup is
    /// on disk, so a thrown error from the block leaves the original
    /// file intact (and a harmless extra backup file).
    @discardableResult
    public static func mutateClaudeSettings(
        directory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default,
        lockTimeout: TimeInterval = defaultLockTimeoutSeconds,
        _ block: @Sendable (inout [String: Any]) throws -> Void
    ) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try withSettingsLock(directory: directory, timeout: lockTimeout) {
            let url = settingsURL(directory: directory)
            var settings = try currentSettings(directory: directory, fileManager: fileManager)
            let backup = try backupIfExists(at: url, fileManager: fileManager)
            try block(&settings)
            let data = try serializeSettings(settings)
            try data.write(to: url, options: .atomic)
            return backup
        }
    }

    /// Bytes-level mutation. For callers that already produce raw JSON
    /// (e.g. ones that go through a separate serializer like
    /// `ClaudeHookInstaller`). The producer is handed the existing
    /// file's bytes — `nil` if absent — and returns a `WriteOutcome`.
    ///
    /// Backup happens before any `write` or `delete` outcome reaches the
    /// filesystem. `noChange` skips both backup and write.
    @discardableResult
    public static func writeClaudeSettings(
        directory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default,
        lockTimeout: TimeInterval = defaultLockTimeoutSeconds,
        _ producer: @Sendable (Data?) throws -> WriteOutcome
    ) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try withSettingsLock(directory: directory, timeout: lockTimeout) {
            let url = settingsURL(directory: directory)
            let existing = try? Data(contentsOf: url)
            let outcome = try producer(existing)
            switch outcome {
            case .noChange:
                return nil
            case .write(let data):
                let backup = try backupIfExists(at: url, fileManager: fileManager)
                try data.write(to: url, options: .atomic)
                return backup
            case .delete:
                let backup = try backupIfExists(at: url, fileManager: fileManager)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                return backup
            }
        }
    }

    // MARK: - Restore / list

    /// Restore from the most recent `.backup.<timestamp>` file by
    /// copying it back over `settings.json`.
    public static func restoreLatestBackup(
        directory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default
    ) throws {
        let backups = listBackups(directory: directory, fileManager: fileManager)
        guard let newest = backups.first else {
            throw ClaudeSettingsBackupError.noBackupFound
        }
        let url = settingsURL(directory: directory)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.copyItem(at: newest, to: url)
    }

    /// List existing backup files sorted newest-first.
    public static func listBackups(
        directory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let prefix = "\(settingsFileName).\(backupExtensionPrefix)"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Internals

    static func settingsURL(directory: URL) -> URL {
        directory.appendingPathComponent(settingsFileName)
    }

    static func lockURL(directory: URL) -> URL {
        directory.appendingPathComponent(lockFileName)
    }

    /// Wrap `body` in an exclusive flock(2) advisory lock on
    /// `<directory>/settings.json.lock`. The lock file is created on
    /// first use and deliberately left on disk after release — flock
    /// is fd-scoped, so file persistence is harmless and lets concurrent
    /// processes share the same inode without coordination tricks.
    ///
    /// flock has no native blocking-with-timeout, so we poll
    /// `LOCK_EX | LOCK_NB` with a 50 ms `usleep` backoff until the
    /// deadline. Throws `.lockContention` on timeout, `.lockSystemError`
    /// on other failures.
    ///
    /// `usleep` (not `Task.sleep`) because the public API is sync to
    /// preserve the existing 6 caller sites unchanged. If a future async
    /// caller needs cooperative-scheduler friendliness, add an `async`
    /// overload that internally uses `Task.sleep`; the current 50 ms
    /// backoff in a contention-rare path is acceptable.
    ///
    /// `defer` order matters: `close(fd)` is registered FIRST so that
    /// LIFO unwinding runs `flock(_, LOCK_UN)` first and `close(fd)`
    /// second. Reversing the order would close the fd while the lock
    /// is still nominally held; on macOS the kernel auto-releases on
    /// close, but the explicit unlock-then-close sequence is the
    /// behavior tools / debuggers expect.
    static func withSettingsLock<T>(
        directory: URL,
        timeout: TimeInterval,
        _ body: () throws -> T
    ) throws -> T {
        let lockPath = lockURL(directory: directory).path
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        guard fd >= 0 else {
            throw ClaudeSettingsBackupError.lockSystemError(errno: errno)
        }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err != EWOULDBLOCK {
                throw ClaudeSettingsBackupError.lockSystemError(errno: err)
            }
            if Date() >= deadline {
                throw ClaudeSettingsBackupError.lockContention
            }
            usleep(50_000)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }

    @discardableResult
    private static func backupIfExists(
        at url: URL,
        fileManager: FileManager
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("\(ClaudeSettingsBackupHelper.backupExtensionPrefix)\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
        return backupURL
    }
}
