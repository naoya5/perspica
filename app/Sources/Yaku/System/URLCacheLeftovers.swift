import Foundation

/// Removes the URL cache that builds before 2026-11-09 left behind: every
/// streamed translation, written by `URLSession.shared` to the app's folder in
/// `~/Library/Caches`. The engine client no longer writes there, so this only
/// ever deletes old data.
enum URLCacheLeftovers {
    private static let names = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    /// The bundled app caches under its bundle identifier; the bare release
    /// binary under its process name.
    private static var folders: [URL] {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return []
        }
        let owners = Set([Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processName].compactMap { $0 })
        return owners.map { caches.appendingPathComponent($0) }
    }

    /// Does nothing under `--data-dir`, which must not touch the user's files.
    static func remove() {
        guard !AppPaths.isUsingDataDirectory else { return }
        var removed = 0
        for folder in folders {
            for name in names {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        if removed > 0 { AppLog.write("url cache: removed \(removed) leftover item(s)") }
    }
}
