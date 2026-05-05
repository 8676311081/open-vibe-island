import Foundation
import os

/// H-5 mitigation: visibility for the merge step every installer
/// already performs.
///
/// Audit finding H-5 originally read as "Open Island silently
/// overwrites the user's `~/.claude/settings.json` etc." — that's
/// inaccurate. Each installer (Claude/Codex/Cursor/Gemini) calls a
/// `*Installer.installHooksJSON(existingData:hookCommand:)` mutator
/// that:
///   1. Loads the existing JSON (or starts fresh on missing file).
///   2. Iterates over current hook events; on each event, runs
///      `sanitizeForInstall` which **filters out only the
///      Open-Island-managed entry** so the new install can replace
///      it. User-authored hooks survive.
///   3. Calls `backupFile(at:)` BEFORE writing — every install
///      lands a `.backup.<ISO-8601>` next to the file.
///
/// What was missing: visibility. The user has no signal that
/// Open Island looked at their config. Console.app log lines fix
/// that without introducing a blocking dialog: a developer
/// suspecting hook-config drift can `log show --predicate
/// 'subsystem == "app.openisland" AND category ==
/// "HookConfigOwnership"'` and see exactly which user-authored
/// entries Open Island observed and preserved.
///
/// This helper is the single owner of that classification logic so
/// all four installers report identically.
public enum HookConfigOwnership {
    private static let logger = Logger(
        subsystem: "app.openisland",
        category: "HookConfigOwnership"
    )

    /// Provider tag used in log lines to disambiguate which install
    /// flow surfaced a finding. Maps 1:1 to the four installer
    /// classes that call this helper.
    public enum Provider: String, Sendable {
        case claude
        case codex
        case cursor
        case gemini
    }

    /// Inspect `existingData` (raw JSON bytes from the on-disk
    /// hook config file, `nil` if the file is absent) and emit a
    /// log line classifying what we found:
    ///
    /// - **No file / empty file** → `.info` "fresh install"
    /// - **File exists, only managed entries** → `.info`
    ///   "replacing Open-Island-managed entries"
    /// - **File exists with user-authored hooks** → `.notice`
    ///   "PRESERVING N user-authored hooks; backup written before
    ///   write" — surfaces the merge guarantee in user-visible
    ///   wording.
    ///
    /// Pure observation: emits log lines, never mutates state.
    /// Safe to call from any installer's pre-write path.
    ///
    /// `managedCommandSubstring` is the per-install
    /// `OpenIslandHooks` invocation; any hook entry whose `command`
    /// contains that substring is treated as Open-Island-managed,
    /// everything else is user-authored. The same heuristic the
    /// installer's own `sanitizeForInstall` uses, lifted here so
    /// the log classification stays consistent with what the
    /// mutator does.
    public static func describeExistingConfig(
        provider: Provider,
        configURL: URL,
        existingData: Data?,
        managedCommandSubstring: String
    ) {
        guard let existingData, !existingData.isEmpty else {
            logger.info(
                "[\(provider.rawValue, privacy: .public)] fresh install — no prior config at \(configURL.path, privacy: .public)"
            )
            return
        }
        let counts = countHookEntries(
            in: existingData,
            managedCommandSubstring: managedCommandSubstring
        )
        if counts.userAuthored == 0 {
            logger.info(
                "[\(provider.rawValue, privacy: .public)] reusing config at \(configURL.path, privacy: .public) — \(counts.managed, privacy: .public) Open-Island-managed entries will be replaced; no user-authored hooks present"
            )
        } else {
            logger.notice(
                "[\(provider.rawValue, privacy: .public)] PRESERVING \(counts.userAuthored, privacy: .public) user-authored hook(s) at \(configURL.path, privacy: .public); replacing \(counts.managed, privacy: .public) Open-Island-managed entries; backup written before write"
            )
        }
    }

    // MARK: - Internals

    /// (managed, userAuthored) counts. Walks any JSON shape that
    /// looks like the four supported config families:
    ///   - Claude / Gemini: `{"hooks": {"<event>": [{"hooks": [{"command": "..."}]}]}}`
    ///   - Codex: same shape under `"hooks"` key
    ///   - Cursor: same shape under `"hooks"` key
    /// Best-effort — unknown shapes simply contribute zero.
    static func countHookEntries(
        in data: Data,
        managedCommandSubstring: String
    ) -> (managed: Int, userAuthored: Int) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return (0, 0)
        }
        var managed = 0
        var userAuthored = 0

        // Walk: root.hooks → eventName → [Group] → group.hooks → [{command}]
        if let hooks = root["hooks"] as? [String: Any] {
            for (_, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                for groupAny in groups {
                    guard
                        let group = groupAny as? [String: Any],
                        let entries = group["hooks"] as? [Any]
                    else { continue }
                    for entryAny in entries {
                        guard
                            let entry = entryAny as? [String: Any],
                            let command = entry["command"] as? String
                        else { continue }
                        if command.contains(managedCommandSubstring) {
                            managed += 1
                        } else {
                            userAuthored += 1
                        }
                    }
                }
            }
        }
        return (managed, userAuthored)
    }
}
