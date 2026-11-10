import Foundation
import SwiftData
import YakuCore

/// The SwiftData store at `~/Library/Application Support/Yaku/Yaku.store`
/// (SPEC 11). Everything runs on the main actor: the app writes at most a
/// couple of rows per translation, so a background context would only add
/// failure modes.
@MainActor
final class TranslationStore {
    /// SPEC 5.3 caps the cache at 5,000 entries. History has no count cap:
    /// SPEC 4.4 offers 「ずっと」 as a retention period, so only the retention
    /// setting (or the user) removes rows.
    static let maximumCache = 5000

    let container: ModelContainer
    private let context: ModelContext
    private(set) var isInMemory = false
    /// The file that could not be opened when the store fell back to memory,
    /// so the manager can say which file and where the log is. Nil when the
    /// store opened, or when memory was asked for.
    private(set) var unopenedLocation: URL?
    /// The enabled glossary pairs, read once and kept until a glossary row
    /// changes. Every translation and every overlay block asks for them.
    private var enabledGlossaryMemo: [GlossaryPair]?

    init(location: URL? = nil, inMemory: Bool = false) {
        let made = Self.makeContainer(location: inMemory ? nil : (location ?? AppPaths.storeURL), inMemory: inMemory)
        container = made.container
        isInMemory = made.inMemory
        unopenedLocation = made.unopened
        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    private static func makeContainer(
        location: URL?,
        inMemory: Bool
    ) -> (container: ModelContainer, inMemory: Bool, unopened: URL?) {
        let schema = Schema([HistoryItem.self, CacheEntry.self, GlossaryEntry.self, PDFJob.self])
        var unopened: URL?
        if !inMemory, let location {
            do {
                let configuration = ModelConfiguration(schema: schema, url: location)
                return (try ModelContainer(for: schema, configurations: configuration), false, nil)
            } catch {
                AppLog.write("store: could not open \(location.path) (\(error)); using memory")
                unopened = location
            }
        }
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try ModelContainer(for: schema, configurations: configuration), true, unopened)
        } catch {
            fatalError("in-memory store could not be created: \(error)")
        }
    }

    // MARK: history

    func addHistory(_ item: HistoryItem) {
        context.insert(item)
        save()
    }

    /// Inserts several rows with one save (the overlay records a whole screen
    /// of blocks at once).
    func addHistoryBatch(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        for item in items { context.insert(item) }
        save()
    }

    var historyCount: Int {
        (try? context.fetchCount(FetchDescriptor<HistoryItem>())) ?? 0
    }

    /// Newest first, optionally filtered by a substring of the source or the
    /// translation (SPEC 4.4: 検索できる一覧). The filter runs in the store, so
    /// it reaches every kept row, not only the newest
    /// `limit` of them.
    func history(search: String = "", limit: Int = 1000) -> [HistoryItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptor = FetchDescriptor<HistoryItem>(
            predicate: needle.isEmpty ? nil : #Predicate {
                $0.source.localizedStandardContains(needle) || $0.target.localizedStandardContains(needle)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteHistory(_ items: [HistoryItem]) {
        for item in items { context.delete(item) }
        save()
    }

    /// Returns false when the rows could not be read or the deletion could not
    /// be saved, so the privacy control can say the data is still there.
    @discardableResult
    func deleteAllHistory() -> Bool {
        do {
            try context.delete(model: HistoryItem.self)
            try context.save()
            AppLog.write("store: deleted all history rows")
            return true
        } catch {
            context.rollback()
            AppLog.write("store: deleting history failed \(error)")
            return false
        }
    }

    /// Drops rows older than the retention setting (SPEC 5.3: 期間を過ぎたものは
    /// 起動時に消す). `days <= 0` keeps everything.
    @discardableResult
    func pruneHistory(olderThanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.date < cutoff })
        guard let old = try? context.fetch(descriptor), !old.isEmpty else { return 0 }
        for item in old { context.delete(item) }
        save()
        AppLog.write("store: pruned \(old.count) history rows older than \(days) days")
        return old.count
    }

    // MARK: cache

    func cached(key: String) -> String? {
        guard let entry = entry(for: key) else { return nil }
        entry.lastUsed = Date()
        save()
        return entry.target
    }

    func store(key: String, target: String) {
        if let existing = entry(for: key) {
            existing.target = target
            existing.lastUsed = Date()
        } else {
            context.insert(CacheEntry(key: key, target: target, lastUsed: Date()))
        }
        trimCache()
        save()
    }

    /// Looks up many keys with one fetch and one save. Keys without an entry
    /// are absent from the result.
    func cachedBatch(keys: [String]) -> [String: String] {
        let unique = Array(Set(keys))
        guard !unique.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { unique.contains($0.key) })
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return [:] }
        let now = Date()
        var result: [String: String] = [:]
        for entry in entries {
            entry.lastUsed = now
            result[entry.key] = entry.target
        }
        save()
        return result
    }

    /// Stores many translations with one fetch, one trim and one save. A later
    /// entry for the same key wins.
    func storeBatch(_ entries: [(key: String, target: String)]) {
        guard !entries.isEmpty else { return }
        let keys = Array(Set(entries.map(\.key)))
        let descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { keys.contains($0.key) })
        var existing: [String: CacheEntry] = [:]
        for entry in (try? context.fetch(descriptor)) ?? [] { existing[entry.key] = entry }
        let now = Date()
        for (key, target) in entries {
            if let entry = existing[key] {
                entry.target = target
                entry.lastUsed = now
            } else {
                let entry = CacheEntry(key: key, target: target, lastUsed: now)
                context.insert(entry)
                existing[key] = entry
            }
        }
        trimCache()
        save()
    }

    var cacheCount: Int {
        (try? context.fetchCount(FetchDescriptor<CacheEntry>())) ?? 0
    }

    @discardableResult
    func deleteAllCache() -> Bool {
        do {
            try context.delete(model: CacheEntry.self)
            try context.save()
            AppLog.write("store: deleted all cache rows")
            return true
        } catch {
            context.rollback()
            AppLog.write("store: deleting cache failed \(error)")
            return false
        }
    }

    private func entry(for key: String) -> CacheEntry? {
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func trimCache() {
        var descriptor = FetchDescriptor<CacheEntry>(sortBy: [SortDescriptor(\.lastUsed, order: .forward)])
        let total = (try? context.fetchCount(descriptor)) ?? 0
        guard total > Self.maximumCache else { return }
        descriptor.fetchLimit = total - Self.maximumCache
        guard let oldest = try? context.fetch(descriptor) else { return }
        for entry in oldest { context.delete(entry) }
        AppLog.write("store: trimmed \(oldest.count) cache rows")
    }

    // MARK: glossary

    /// Adds the samples the first time the store is used (SPEC 4.4). They are
    /// disabled so the shipped behaviour is unchanged until the user turns one on.
    func seedGlossaryIfNeeded() {
        let count = glossaryCount
        guard count == 0 else { return }
        for entry in GlossaryEntry.samples() { context.insert(entry) }
        enabledGlossaryMemo = nil
        save()
        AppLog.write("store: seeded \(GlossaryEntry.samples().count) glossary samples (disabled)")
    }

    var glossaryCount: Int {
        (try? context.fetchCount(FetchDescriptor<GlossaryEntry>())) ?? 0
    }

    func glossary() -> [GlossaryEntry] {
        let descriptor = FetchDescriptor<GlossaryEntry>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The enabled entries, in table order, as the pairs the prompt uses.
    func enabledGlossaryPairs() -> [GlossaryPair] {
        if let enabledGlossaryMemo { return enabledGlossaryMemo }
        let pairs = glossary().filter(\.enabled).map(\.pair)
        enabledGlossaryMemo = pairs
        return pairs
    }

    func addGlossaryEntry(source: String, target: String, enabled: Bool = true) -> GlossaryEntry {
        let order = (glossary().map(\.sortOrder).max() ?? -1) + 1
        let entry = GlossaryEntry(source: source, target: target, enabled: enabled, sortOrder: order)
        context.insert(entry)
        enabledGlossaryMemo = nil
        save()
        return entry
    }

    func addGlossaryEntries(_ rows: [GlossaryCSV.Row]) {
        var order = (glossary().map(\.sortOrder).max() ?? -1) + 1
        for row in rows {
            context.insert(GlossaryEntry(
                source: row.source,
                target: row.target,
                enabled: row.enabled,
                sortOrder: order
            ))
            order += 1
        }
        enabledGlossaryMemo = nil
        save()
        AppLog.write("store: imported \(rows.count) glossary rows")
    }

    func deleteGlossaryEntries(_ entries: [GlossaryEntry]) {
        for entry in entries { context.delete(entry) }
        enabledGlossaryMemo = nil
        save()
    }

    func glossaryCSV() -> String {
        GlossaryCSV.encode(glossary().map {
            GlossaryCSV.Row(source: $0.source, target: $0.target, enabled: $0.enabled)
        })
    }

    /// Writes the table's new order (drag and drop in the glossary view).
    func reorderGlossary(_ entries: [GlossaryEntry]) {
        for (position, entry) in entries.enumerated() { entry.sortOrder = position }
        enabledGlossaryMemo = nil
        save()
    }

    // MARK: PDF jobs (SPEC 11)

    func addPDFJob(_ job: PDFJob) {
        context.insert(job)
        save()
    }

    /// Newest first, which is the order the PDF page lists them in.
    func pdfJobs() -> [PDFJob] {
        let descriptor = FetchDescriptor<PDFJob>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deletePDFJob(_ job: PDFJob) {
        context.delete(job)
        save()
    }

    /// Flushes pending edits (the glossary table edits rows in place, and the
    /// PDF job's progress is written as it runs).
    func saveNow() {
        // Glossary rows are edited in place and then saved through here, so
        // the memo cannot tell whether one of them changed.
        enabledGlossaryMemo = nil
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.write("store: save failed \(error)")
        }
    }
}
