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

    // MARK: - File-lock coverage
    //
    // Six cases: serial baseline, concurrent producers, cross-process
    // blocking, contention timeout, first-run lock-file creation, and
    // lock-file inode persistence. Cross-process tests shell out to the
    // bundled macOS `/usr/bin/python3` (always present on macOS 12+);
    // they're the only way to hold flock from a separate process and
    // observe blocking from Swift.

    @Test
    func serialBaseline100MutationsAllPersist() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<100 {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
                settings["count"] = i
            }
        }

        let final = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect((final["count"] as? Int) == 99)
    }

    @Test
    func concurrent30MutationsAllEditsPersist() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Sendable bridge: tasks need the URL value, not a captured ref.
        let dirCopy = dir

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    _ = try? ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dirCopy) { settings in
                        settings["key_\(i)"] = i
                    }
                }
            }
        }

        let final = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        for i in 0..<30 {
            #expect(final["key_\(i)"] as? Int == i, "missing key_\(i) under concurrency — lock failed")
        }
    }

    @Test
    func crossProcessLockBlocksMainThread() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockPath = dir.appendingPathComponent("settings.json.lock").path
        FileManager.default.createFile(atPath: lockPath, contents: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
            import fcntl, sys, time
            f = open('\(lockPath)', 'rb+')
            fcntl.flock(f, fcntl.LOCK_EX)
            sys.stdout.write('locked\\n'); sys.stdout.flush()
            time.sleep(0.6)
            """]
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        try proc.run()

        let handle = stdoutPipe.fileHandleForReading
        var output = ""
        let waitStart = Date()
        while !output.contains("locked") {
            #expect(Date().timeIntervalSince(waitStart) < 5, "python helper never reported 'locked'")
            let chunk = handle.availableData
            if chunk.isEmpty { try await Task.sleep(nanoseconds: 10_000_000); continue }
            output += String(data: chunk, encoding: .utf8) ?? ""
        }

        let mutateStart = Date()
        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["x"] = 1
        }
        let elapsed = Date().timeIntervalSince(mutateStart)

        proc.waitUntilExit()

        #expect(elapsed >= 0.4, "mutate should have blocked on cross-process lock; elapsed=\(elapsed)s")
        let final = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(final["x"] as? Int == 1)
    }

    @Test
    func contentionTimeoutThrowsLockContention() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockPath = dir.appendingPathComponent("settings.json.lock").path
        FileManager.default.createFile(atPath: lockPath, contents: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
            import fcntl, sys, time
            f = open('\(lockPath)', 'rb+')
            fcntl.flock(f, fcntl.LOCK_EX)
            sys.stdout.write('locked\\n'); sys.stdout.flush()
            time.sleep(1.5)
            """]
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        try proc.run()

        let handle = stdoutPipe.fileHandleForReading
        var output = ""
        let waitStart = Date()
        while !output.contains("locked") {
            #expect(Date().timeIntervalSince(waitStart) < 5, "python helper never reported 'locked'")
            let chunk = handle.availableData
            if chunk.isEmpty { try await Task.sleep(nanoseconds: 10_000_000); continue }
            output += String(data: chunk, encoding: .utf8) ?? ""
        }

        // Short timeout; python holds for 1.5 s so this must time out.
        var thrown: Error?
        do {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: dir,
                lockTimeout: 0.3
            ) { settings in
                settings["should_not_land"] = true
            }
        } catch {
            thrown = error
        }

        proc.waitUntilExit()

        if let backupError = thrown as? ClaudeSettingsBackupError,
           case .lockContention = backupError {
            // expected
        } else {
            Issue.record("expected ClaudeSettingsBackupError.lockContention, got \(String(describing: thrown))")
        }
        // settings.json should never have been written.
        let final = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect((final["should_not_land"] as? Bool) == nil)
    }

    @Test
    func firstRunCreatesLockFile() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockURL = dir.appendingPathComponent("settings.json.lock")
        #expect(!FileManager.default.fileExists(atPath: lockURL.path), "lock file should not exist before first mutate")

        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["k"] = "v"
        }

        #expect(FileManager.default.fileExists(atPath: lockURL.path), "lock file should be auto-created on first mutate")
    }

    @Test
    func lockFilePersistsWithSameInodeAcrossInvocations() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { s in
            s["a"] = 1
        }
        let lockURL = dir.appendingPathComponent("settings.json.lock")
        let attrs1 = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let inode1 = attrs1[.systemFileNumber] as? UInt64

        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { s in
            s["b"] = 2
        }
        let attrs2 = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let inode2 = attrs2[.systemFileNumber] as? UInt64

        #expect(inode1 != nil, "could not read lock file inode after first mutate")
        #expect(inode1 == inode2, "lock file should be reused (same inode), not recreated; got \(inode1 ?? 0) vs \(inode2 ?? 0)")
    }
}
