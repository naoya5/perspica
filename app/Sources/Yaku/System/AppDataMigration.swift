import Foundation
import YakuCore

enum AppDataMigration {
    static func run() throws {
        guard !AppPaths.isUsingDataDirectory else { return }
        let storeNames: Set<String> = [
            "Yaku.store", "Yaku.store-wal", "Yaku.store-shm", "Yaku.store-journal",
            "Yaku.store_SUPPORT", ".Yaku.store_SUPPORT",
        ]
        let renaming = Dictionary(uniqueKeysWithValues: storeNames.map {
            ($0, $0.replacingOccurrences(of: "Yaku.store", with: "Perspica.store"))
        })
        try LegacyDataMigration.moveDirectory(
            from: AppPaths.legacySupportDirectory,
            to: AppPaths.standardSupportDirectory,
            renaming: renaming,
            // A virtual environment's scripts contain absolute paths. Leave
            // the obsolete Python environment at the old path as a backup.
            excluding: ["Yaku.lock", "pdf-worker", "engine.pid", "engine-watchdog.pid", "engine-watchdog.sh"],
            storeNames: storeNames
        )
        try LegacyDataMigration.moveDirectory(
            from: AppPaths.legacyLogsDirectory,
            to: AppPaths.logsDirectory
        )
    }
}
