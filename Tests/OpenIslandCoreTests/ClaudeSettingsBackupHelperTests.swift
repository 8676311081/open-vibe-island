import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeSettingsBackupHelperTests {
    private static func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-settings-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeSettings(_ json: [String: Any], to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
        return url
    }

    @Test
    func currentSettingsReturnsEmptyDictWhenFileMissing() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(result.isEmpty)
    }

    @Test
    func currentSettingsThrowsWhenRootIsNotObject() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("settings.json")
        try Data("[1, 2, 3]".utf8).write(to: url)

        #expect(throws: ClaudeSettingsBackupError.self) {
            _ = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        }
    }

    @Test
    func mutateCreatesFileWithoutBackupWhenAbsent() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backup = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }

        #expect(backup == nil)
        let written = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(written["theme"] as? String == "light")
        #expect(ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func mutateBacksUpExistingFileBeforeRewriting() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = try Self.writeSettings(["theme": "dark"], to: dir)
        let originalBytes = try Data(contentsOf: original)

        let backup = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }

        let backupURL = try #require(backup)
        let backupBytes = try Data(contentsOf: backupURL)
        #expect(backupBytes == originalBytes)
        #expect(backupURL.lastPathComponent.hasPrefix("settings.json.backup."))

        let updated = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(updated["theme"] as? String == "light")
    }

    @Test
    func mutateBlockThrowingLeavesOriginalFileButProducesBackup() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["x": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        struct BlockError: Error {}
        do {
            _ = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { _ in
                throw BlockError()
            }
            Issue.record("expected throw")
        } catch is BlockError {
            // expected
        }

        // settings.json untouched
        #expect(try Data(contentsOf: url) == originalBytes)
        // backup did land (mutate guarantees backup BEFORE block runs)
        #expect(!ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func writeOutcomeNoChangeSkipsBackupAndWrite() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .noChange
        }

        #expect(backup == nil)
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func writeOutcomeWriteBackupsAndPersists() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)
        let newBytes = Data(#"{"a":2}"#.utf8)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .write(newBytes)
        }

        let backupURL = try #require(backup)
        #expect(try Data(contentsOf: backupURL) == originalBytes)
        #expect(try Data(contentsOf: url) == newBytes)
    }

    @Test
    func writeOutcomeDeleteBackupsAndRemoves() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .delete
        }

        let backupURL = try #require(backup)
        #expect(try Data(contentsOf: backupURL) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func listBackupsReturnsNewestFirst() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three timestamped backup files; lexical descending == chronological newest-first
        let names = [
            "settings.json.backup.2026-01-01T00-00-00Z",
            "settings.json.backup.2026-05-01T20-53-50Z",
            "settings.json.backup.2026-03-15T12-00-00Z",
        ]
        for n in names {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(n))
        }

        let listed = ClaudeSettingsBackupHelper.listBackups(directory: dir)
        #expect(listed.map(\.lastPathComponent) == [
            "settings.json.backup.2026-05-01T20-53-50Z",
            "settings.json.backup.2026-03-15T12-00-00Z",
            "settings.json.backup.2026-01-01T00-00-00Z",
        ])
    }

    @Test
    func restoreLatestBackupCopiesNewestOverSettings() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalBytes = Data(#"{"theme":"dark"}"#.utf8)
        let url = dir.appendingPathComponent("settings.json")
        try originalBytes.write(to: url)

        // mutate creates backup, then restore should bring original back byte-identical
        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }
        try ClaudeSettingsBackupHelper.restoreLatestBackup(directory: dir)

        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test
    func restoreLatestBackupThrowsWhenNoBackupExists() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ClaudeSettingsBackupError.self) {
            try ClaudeSettingsBackupHelper.restoreLatestBackup(directory: dir)
        }
    }

    // MARK: - Output formatting (matches Claude Code's native shape)

    /// helper output is structurally what Claude Code's settings.json
    /// writer produces:  no escaped forward slashes, and no leading
    /// space before the colon that separates a JSON key from its
    /// value. Both pin formatting drift on round-trip — without these,
    /// `git diff settings.json` after a single Open Island
    /// install/uninstall flashes ~50 false-positive line changes.
    @Test
    func serializeSettingsDoesNotEscapeSlashOrLeadColonWithSpace() throws {
        let dict: [String: Any] = [
            "command": "/Users/qwen/.open-island/bin/rtk",
            "nested": ["foo": "bar"],
        ]
        let bytes = try ClaudeSettingsBackupHelper.serializeSettings(dict)
        let s = String(data: bytes, encoding: .utf8) ?? ""

        // No backslash-escaped forward slash anywhere.
        #expect(!s.contains("\\/"))
        // No structural ` : ` (colon with leading space) on any line.
        // We do allow ` : ` inside a string value — but the regression
        // we're guarding against is the structural one.
        for line in s.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(!trimmed.contains(#"" : "#),
                    "found leading-space colon in line: \(line)")
        }
    }

    /// Colon-space normalizer must not touch `:` that appears inside
    /// a JSON string value (e.g. URLs, time-of-day strings, free text).
    @Test
    func normalizeColonSpacingLeavesInStringColonsAlone() {
        let input = #"""
        {
          "url" : "http://example.com:8080/path",
          "msg" : "key : value pair in user text"
        }
        """#
        let normalized = ClaudeSettingsBackupHelper.normalizeColonSpacing(input)
        // Structural colons are flush.
        #expect(normalized.contains(#""url": "#))
        #expect(normalized.contains(#""msg": "#))
        // In-string colons are unchanged.
        #expect(normalized.contains(#"http://example.com:8080/path"#))
        #expect(normalized.contains(#"key : value pair in user text"#))
    }

    /// Backslash escapes inside JSON strings shouldn't fool the
    /// colon-space state machine. `"\""` is a single escaped quote
    /// that must not flip us out of the in-string state, and
    /// `"\\"` is an escaped backslash that resumes the string.
    @Test
    func normalizeColonSpacingHandlesEscapedQuotesAndBackslashes() {
        let input = #"""
        {
          "a" : "x\"y : z",
          "b" : "trail\\",
          "c" : "after"
        }
        """#
        let normalized = ClaudeSettingsBackupHelper.normalizeColonSpacing(input)
        // `"a": ` flushed; the in-string `: z` survives.
        #expect(normalized.contains(#""a": "#))
        #expect(normalized.contains(#"x\"y : z"#))
        // After the trailing `\\` string ends; the next `"c" :` flushed.
        #expect(normalized.contains(#""c": "#))
    }
}
