import Foundation
import SwiftData
import YakuCore

/// The SwiftData store at `~/Library/Application Support/Yaku/Yaku.store`
/// (SPEC 11). Everything runs on the main actor: the app writes at most a
/// couple of rows per translation, so a background context would only add
/// failure modes.
@MainActor
final class TranslationStore {
    /// SPEC 5.3 caps the cache at 5,000 entries. History uses the same cap so
    /// the store cannot grow without bound even with retention off.
    static let maximumHistory = 5000
    static let maximumCache = 5000

    let container: ModelContainer
    private let context: ModelContext
    private(set) var isInMemory = false

    init(location: URL? = nil, inMemory: Bool = false) {
        let made = Self.makeContainer(location: inMemory ? nil : (location ?? AppPaths.storeURL), inMemory: inMemory)
        container = made.container
        isInMemory = made.inMemory
        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    private static func makeContainer(location: URL?, inMemory: Bool) -> (container: ModelContainer, inMemory: Bool) {
        let schema = Schema([HistoryItem.self, CacheEntry.self, GlossaryEntry.self, PDFJob.self])
        if !inMemory, let location {
            do {
                let configuration = ModelConfiguration(schema: schema, url: location)
                return (try ModelContainer(for: schema, configurations: configuration), false)
            } catch {
                AppLog.write("store: could not open \(location.path) (\(error)); using memory")
            }
        }
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try ModelContainer(for: schema, configurations: configuration), true)
        } catch {
            fatalError("in-memory store could not be created: \(error)")
        }
    }

    // MARK: history

    func addHistory(_ item: HistoryItem) {
        context.insert(item)
        trimHistory()
        save()
    }

    var historyCount: Int {
        (try? context.fetchCount(FetchDescriptor<HistoryItem>())) ?? 0
    }

    /// Newest first, optionally filtered by a substring of the source or the
    /// translation (SPEC 4.4: 検索できる一覧). The filter runs in the store, so
    /// it reaches every kept row (up to `maximumHistory`), not only the newest
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

    func deleteAllHistory() {
        let items = (try? context.fetch(FetchDescriptor<HistoryItem>())) ?? []
        for item in items { context.delete(item) }
        save()
        AppLog.write("store: deleted \(items.count) history rows")
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

    private func trimHistory() {
        var descriptor = FetchDescriptor<HistoryItem>(sortBy: [SortDescriptor(\.date, order: .forward)])
        let total = (try? context.fetchCount(descriptor)) ?? 0
        guard total > Self.maximumHistory else { return }
        descriptor.fetchLimit = total - Self.maximumHistory
        guard let oldest = try? context.fetch(descriptor) else { return }
        for item in oldest { context.delete(item) }
        AppLog.write("store: trimmed \(oldest.count) history rows")
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

    var cacheCount: Int {
        (try? context.fetchCount(FetchDescriptor<CacheEntry>())) ?? 0
    }

    func deleteAllCache() {
        let entries = (try? context.fetch(FetchDescriptor<CacheEntry>())) ?? []
        for entry in entries { context.delete(entry) }
        save()
        AppLog.write("store: deleted \(entries.count) cache rows")
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
        glossary().filter(\.enabled).map(\.pair)
    }

    func addGlossaryEntry(source: String, target: String, enabled: Bool = true) -> GlossaryEntry {
        let order = (glossary().map(\.sortOrder).max() ?? -1) + 1
        let entry = GlossaryEntry(source: source, target: target, enabled: enabled, sortOrder: order)
        context.insert(entry)
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
        save()
        AppLog.write("store: imported \(rows.count) glossary rows")
    }

    func deleteGlossaryEntries(_ entries: [GlossaryEntry]) {
        for entry in entries { context.delete(entry) }
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
