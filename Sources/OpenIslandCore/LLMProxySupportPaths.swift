import Darwin
import Foundation

/// Filesystem layout for the local LLM proxy.
///
/// Co-located under the same `~/Library/Application Support/OpenIsland/`
/// directory the Bridge socket already uses, so a future `du -sh` shows one
/// honest footprint for everything Open Island writes.
public enum LLMProxySupportPaths {
    public static var directoryURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("OpenIsland")
    }

    public static var pidFileURL: URL {
        directoryURL.appendingPathComponent("proxy.pid")
    }

    public static var statsFileURL: URL {
        directoryURL.appendingPathComponent("llm-stats.json")
    }

    public static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}

public enum LLMProxyPIDFile {
    public static func write(pid: Int32 = getpid(), to url: URL = LLMProxySupportPaths.pidFileURL) {
        try? LLMProxySupportPaths.ensureDirectoryExists()
        let payload = "\(pid)\n"
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public static func clear(at url: URL = LLMProxySupportPaths.pidFileURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
