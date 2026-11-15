import Foundation
import Testing
@testable import YakuCore

struct LegacyDataMigrationTests {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Yaku")
        let new = root.appendingPathComponent("Perspica")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try body(old, new)
    }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func movesDataAndStoreSidecarsButNotWorkerOrLock() throws {
        try fixture { old, new in
            for name in ["Yaku.store", "Yaku.store-wal", ".Yaku.store_SUPPORT/blobs", "models/model.gguf",
                         "pdf-worker/bin/python", "Yaku.lock"] {
                try put(name, at: old.appendingPathComponent(name))
            }
            try LegacyDataMigration.moveDirectory(
                from: old, to: new,
                renaming: ["Yaku.store": "Perspica.store", "Yaku.store-wal": "Perspica.store-wal",
                           ".Yaku.store_SUPPORT": ".Perspica.store_SUPPORT"],
                excluding: ["pdf-worker", "Yaku.lock"]
            )
            #expect(try String(contentsOf: new.appendingPathComponent("Perspica.store-wal"), encoding: .utf8) == "Yaku.store-wal")
            #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent(".Perspica.store_SUPPORT/blobs").path))
            #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("models/model.gguf").path))
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("pdf-worker/bin/python").path))
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("Yaku.lock").path))
        }
    }

    @Test func destinationWinsAndCompletionDoesNotRestoreDeletedData() throws {
        try fixture { old, new in
            try put("old", at: old.appendingPathComponent("app.log"))
            try put("new", at: new.appendingPathComponent("app.log"))
            try put("model", at: old.appendingPathComponent("models/model.gguf"))
            try LegacyDataMigration.moveDirectory(from: old, to: new)
            #expect(try String(contentsOf: new.appendingPathComponent("app.log"), encoding: .utf8) == "new")
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("app.log").path))
            try FileManager.default.removeItem(at: new.appendingPathComponent("models"))
            try FileManager.default.removeItem(at: new.appendingPathComponent("app.log"))
            try LegacyDataMigration.moveDirectory(from: old, to: new)
            #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("app.log").path))
            #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("models").path))
        }
    }

    @Test func storeConflictKeepsEntireLegacyStoreTogether() throws {
        try fixture { old, new in
            try put("old-db", at: old.appendingPathComponent("Yaku.store"))
            try put("old-wal", at: old.appendingPathComponent("Yaku.store-wal"))
            try put("new-db", at: new.appendingPathComponent("Perspica.store"))
            try LegacyDataMigration.moveDirectory(
                from: old, to: new,
                renaming: ["Yaku.store": "Perspica.store", "Yaku.store-wal": "Perspica.store-wal"],
                storeNames: ["Yaku.store", "Yaku.store-wal"]
            )
            #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("Perspica.store-wal").path))
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("Yaku.store-wal").path))
        }
    }

    @Test func resumesAfterInterruption() throws {
        try fixture { old, new in
            try put("already moved", at: new.appendingPathComponent("Perspica.store"))
            try put("remaining", at: old.appendingPathComponent("Yaku.store-wal"))
            let journal = """
            {"entries":{"Yaku.store":"Perspica.store","Yaku.store-wal":"Perspica.store-wal"},"complete":false}
            """
            try put(journal, at: new.appendingPathComponent(".yaku-migration-v1.json"))
            try LegacyDataMigration.moveDirectory(from: old, to: new)
            #expect(try String(contentsOf: new.appendingPathComponent("Perspica.store-wal"), encoding: .utf8) == "remaining")
        }
    }

    @Test func newConflictAfterInterruptionStopsWithoutOverwriting() throws {
        try fixture { old, new in
            try put("source", at: old.appendingPathComponent("data"))
            try put("destination", at: new.appendingPathComponent("data"))
            try put(#"{"entries":{"data":"data"},"complete":false}"#,
                    at: new.appendingPathComponent(".yaku-migration-v1.json"))
            #expect(throws: (any Error).self) {
                try LegacyDataMigration.moveDirectory(from: old, to: new)
            }
            #expect(try String(contentsOf: new.appendingPathComponent("data"), encoding: .utf8) == "destination")
        }
    }

    @Test func corruptJournalFailsClosed() throws {
        try fixture { old, new in
            try put("invalid", at: new.appendingPathComponent(".yaku-migration-v1.json"))
            #expect(throws: (any Error).self) {
                try LegacyDataMigration.moveDirectory(from: old, to: new)
            }
        }
    }

    @Test func preferencesPreserveCurrentAndOnlyImportKnownKeys() throws {
        try fixture { old, new in
            try put("model", at: new.appendingPathComponent("models/model.gguf"))
            let values = LegacyDataMigration.settings(
                legacy: ["keepHistory": false, "engineIdleMinutes": 12, "unrelated": "skip",
                         "modelPath": old.appendingPathComponent("models/model.gguf").path,
                         "pdfPythonPath": old.appendingPathComponent("pdf-worker/bin/python").path],
                current: ["engineIdleMinutes": 3],
                keys: ["keepHistory", "engineIdleMinutes", "modelPath", "pdfPythonPath"],
                oldSupport: old, newSupport: new
            )
            #expect(values["keepHistory"] as? Bool == false)
            #expect(values["engineIdleMinutes"] as? Int == 3)
            #expect(values["unrelated"] == nil)
            #expect(values["modelPath"] as? String == new.appendingPathComponent("models/model.gguf").path)
            #expect(values["pdfPythonPath"] as? String == "")
        }
    }

    @Test func externalAndUnmovedModelPathsStayUntouched() throws {
        try fixture { old, new in
            let missing = old.appendingPathComponent("models/not-moved.gguf").path
            let values = LegacyDataMigration.settings(
                legacy: ["modelPath": missing, "pdfPythonPath": "/opt/custom/bin/python"],
                current: [:], keys: ["modelPath", "pdfPythonPath"], oldSupport: old, newSupport: new
            )
            #expect(values["modelPath"] as? String == missing)
            #expect(values["pdfPythonPath"] as? String == "/opt/custom/bin/python")
        }
    }
}
