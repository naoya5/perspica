import Foundation

/// A one-time, resumable move. Existing destination entries always win.
/// Callers must hold both the current and legacy app's instance locks.
public enum LegacyDataMigration {
    private struct Journal: Codable {
        var entries: [String: String]
        var complete: Bool
    }

    public static func moveDirectory(
        from source: URL,
        to destination: URL,
        renaming: [String: String] = [:],
        excluding: Set<String> = [],
        storeNames: Set<String> = []
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let journalURL = destination.appendingPathComponent(".yaku-migration-v1.json")
        var journal: Journal
        if manager.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        } else {
            let names = manager.fileExists(atPath: source.path)
                ? try manager.contentsOfDirectory(atPath: source.path) : []
            // A SQLite store and its WAL/SHM/external-data files are one unit.
            // Never combine an old store with a destination store's sidecars.
            let hasCurrentStore = storeNames.contains {
                manager.fileExists(atPath: destination.appendingPathComponent(renaming[$0] ?? $0).path)
            }
            var entries: [String: String] = [:]
            for name in names where !excluding.contains(name) {
                guard !hasCurrentStore || !storeNames.contains(name) else { continue }
                let target = renaming[name] ?? name
                if !manager.fileExists(atPath: destination.appendingPathComponent(target).path) {
                    entries[name] = target
                }
            }
            journal = Journal(entries: entries, complete: false)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        }
        guard !journal.complete else { return }
        for name in journal.entries.keys.sorted() {
            let old = source.appendingPathComponent(name)
            let new = destination.appendingPathComponent(journal.entries[name]!)
            let oldExists = manager.fileExists(atPath: old.path)
            let newExists = manager.fileExists(atPath: new.path)
            if oldExists && !newExists {
                try manager.moveItem(at: old, to: new)
            } else if oldExists || !newExists {
                // A new conflict or a missing entry after journaling needs a
                // person's attention, not an overwrite or an empty new store.
                throw CocoaError(.fileWriteFileExists)
            }
        }
        journal.complete = true
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    /// Only managed paths that actually moved are rewritten. External paths
    /// and destination preferences are never replaced.
    public static func settings(
        legacy: [String: Any],
        current: [String: Any],
        keys: [String],
        oldSupport: URL,
        newSupport: URL
    ) -> [String: Any] {
        var result = current
        for key in keys where result[key] == nil {
            result[key] = legacy[key]
        }
        for key in ["modelPath", "pdfPythonPath", "pdfOutputFolder"] {
            guard let path = result[key] as? String,
                  path.hasPrefix(oldSupport.path + "/") else { continue }
            if key == "pdfPythonPath",
               path.hasPrefix(oldSupport.appendingPathComponent("pdf-worker").path + "/") {
                result[key] = ""
                continue
            }
            let newPath = newSupport.path + path.dropFirst(oldSupport.path.count)
            if FileManager.default.fileExists(atPath: newPath) { result[key] = newPath }
        }
        return result
    }
}
