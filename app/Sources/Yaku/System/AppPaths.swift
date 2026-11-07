import Foundation
import YakuCore

/// Every path the app writes to, all under the user's Library.
///
/// `--data-dir <folder>` replaces the Application Support directory with the
/// given folder (SPEC 15: 初めてのユーザーとして試すため). The logs stay where
/// they are so a demo run is still visible in `~/Library/Logs/Yaku`.
enum AppPaths {
    /// `--data-dir` is read from the command line directly, so every path is
    /// already correct the first time it is asked for.
    nonisolated(unsafe) private static var overrideSupport: URL? = {
        guard let value = LaunchArguments.dataDirectory, !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isUsingDataDirectory: Bool { overrideSupport != nil }

    /// The real Application Support folder, ignoring `--data-dir`.
    static var standardSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return ensure(base.appendingPathComponent("Yaku"))
    }

    static var supportDirectory: URL {
        if let overrideSupport { return ensure(overrideSupport) }
        return standardSupportDirectory
    }

    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return ensure(base.appendingPathComponent("Logs/Yaku"))
    }

    static var enginePIDFile: URL { supportDirectory.appendingPathComponent("engine.pid") }
    static var storeURL: URL { supportDirectory.appendingPathComponent("Yaku.store") }
    static var modelsDirectory: URL { ensure(supportDirectory.appendingPathComponent("models")) }
    /// Only one Yaku runs at a time (SPEC 7.1). The lock is deliberately in the
    /// standard folder even under `--data-dir`, so two demo runs cannot both be
    /// up at once.
    static var lockFile: URL { standardSupportDirectory.appendingPathComponent("Yaku.lock") }
    /// The shell script the watchdog runs (SPEC 7.1).
    static var watchdogScript: URL { supportDirectory.appendingPathComponent("engine-watchdog.sh") }
    /// Where the watchdog writes the llama-server pid it started.
    static var watchdogPidFile: URL { supportDirectory.appendingPathComponent("engine-watchdog.pid") }
    /// The settings file used instead of `UserDefaults` when `--data-dir` is set.
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var engineLog: URL { logsDirectory.appendingPathComponent("engine.log") }
    static var appLog: URL { logsDirectory.appendingPathComponent("app.log") }
    static var pdfLog: URL { logsDirectory.appendingPathComponent("pdf.log") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Timestamped, append-only record of what the app did. Used to check
/// behaviour that cannot be observed on screen.
enum AppLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let url = AppPaths.appLog

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
