import Foundation

public enum ClaudeSettingsBackupError: LocalizedError, Sendable {
    case invalidSettingsRoot
    case noBackupFound

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsRoot:
            return "Claude Code settings.json must contain a top-level object."
        case .noBackupFound:
            return "No Claude settings backup file found."
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
        _ block: (inout [String: Any]) throws -> Void
    ) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = settingsURL(directory: directory)

        var settings = try currentSettings(directory: directory, fileManager: fileManager)
        let backup = try backupIfExists(at: url, fileManager: fileManager)

        try block(&settings)

        let data = try serializeSettings(settings)
        try data.write(to: url, options: .atomic)
        return backup
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
        _ producer: (Data?) throws -> WriteOutcome
    ) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
