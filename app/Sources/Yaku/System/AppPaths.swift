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
///
/// The log records what the app did and how long it took, never what the user
/// translated: lines that would carry source text, a translation, a glossary
/// pair or a demo sentence go through `content(_:)`, which writes nothing
/// unless content logging is on.
enum AppLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    /// SPEC 11: each log switches to a new file at 5 MB, and at most three
    /// files are kept per log (`app.log`, `app.log.1`, `app.log.2`).
    static let rotateAbove = RotatingLogFile.maximumBytes
    static let keptFiles = RotatingLogFile.keptFiles

    /// Whether `content(_:)` writes. `YAKU_LOG_CONTENT=1` or `=0` decides when
    /// it is set; otherwise a `--data-dir` run (a demo or verification run
    /// that never touches real data) turns it on and a normal launch leaves it
    /// off. The verify helper reads `demo-translate result=` from the log, so
    /// its runs need it on.
    static let logsContent: Bool = {
        if let value = ProcessInfo.processInfo.environment["YAKU_LOG_CONTENT"] {
            return value == "1"
        }
        return LaunchArguments.dataDirectory != nil
    }()

    /// A line that carries user text. Dropped unless `logsContent` is true.
    static func content(_ line: @autoclosure () -> String) {
        guard logsContent else { return }
        write(line())
    }

    static var allLogs: [URL] { [AppPaths.appLog, AppPaths.engineLog, AppPaths.pdfLog] }

    /// `<name>.log.<n>`, the n-th older file of a log.
    static func archive(of url: URL, index: Int) -> URL {
        RotatingLogFile.archive(of: url, index: index)
    }

    /// Rotates every log that is over the limit. Called at launch.
    static func rotateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        for url in allLogs { rotateLocked(url) }
    }

    /// Rotates one log if it is over the limit. The engine and the PDF worker
    /// call this before they open their log for a new child process.
    static func rotateIfNeeded(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        rotateLocked(url)
    }

    private static func rotateLocked(_ url: URL) {
        try? RotatingLogFile.rotateIfNeeded(url)
    }

    /// Empties every log the app writes (`app.log`, `engine.log`, `pdf.log`)
    /// and removes their older files, for the privacy controls. The current
    /// files stay so open handles keep working. Returns false when any of them
    /// could not be emptied or removed.
    @discardableResult
    static func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        var ok = true
        for url in allLogs {
            for index in 1..<keptFiles {
                let old = archive(of: url, index: index)
                guard manager.fileExists(atPath: old.path) else { continue }
                if (try? manager.removeItem(at: old)) == nil { ok = false }
            }
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            } catch {
                ok = false
            }
        }
        return ok
    }

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        appendLocked(data, to: AppPaths.appLog)
    }

    /// Appends to a log, splitting writes before reaching the file limit.
    static func append(_ data: Data, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(data, to: url)
    }

    private static func appendLocked(_ data: Data, to url: URL) {
        try? RotatingLogFile.append(data, to: url)
    }

    /// A pipe for a child's stdout or stderr whose output the app appends to
    /// `url` with the same rotation, instead of the child writing the file
    /// directly and growing it without a bound while it runs.
    static func rotatingPipe(for url: URL) -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            append(data, to: url)
        }
        return pipe
    }
}
