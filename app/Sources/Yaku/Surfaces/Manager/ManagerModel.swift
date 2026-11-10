import AppKit
import Foundation
import Observation
import SwiftData
import YakuCore

/// Everything the manager window reads and does (SPEC 4.4).
///
/// The store's SwiftData fetches are not observable by themselves, so the lists
/// the views show are held here and reloaded after every change. That keeps the
/// table and the history list honest without scattering `@Query` through five
/// views.
@MainActor
@Observable
final class ManagerModel {
    let store: TranslationStore
    let engine: EngineManager
    let downloader = ModelDownloader()

    var history: [HistoryItem] = []
    var glossary: [GlossaryEntry] = []
    /// Searched 200 ms after the last keystroke, not on every one.
    var historySearch = "" {
        didSet {
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                self?.reloadHistory()
            }
        }
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var selectedHistory: HistoryItem?
    var selectedGlossary: Set<PersistentIdentifier> = []

    /// Installed state per catalogue model, refreshed after a download.
    var installed: [String: Bool] = [:]
    var modelNote: String?
    /// The model whose licence is being shown; the download waits for consent.
    var licenseModel: TranslationModel?

    init(store: TranslationStore, engine: EngineManager) {
        self.store = store
        self.engine = engine
        downloader.onFinished = { [weak self] model in
            self?.modelFinished(model)
        }
        reloadHistory()
        reloadGlossary()
        refreshInstalled()
    }

    // MARK: history

    func reloadHistory() {
        history = store.history(search: historySearch)
        if !historySearch.isEmpty {
            AppLog.write("history: search matched \(history.count) row(s)")
        }
    }

    func deleteHistory(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        store.deleteHistory(items)
        if let selected = selectedHistory, items.contains(where: { $0 === selected }) {
            selectedHistory = nil
        }
        reloadHistory()
    }

    /// The history rows' 「訳文をコピー」 and 「原文をコピー」.
    func copy(_ text: String) {
        guard Clipboard.copy(text) else { return }
        AppLog.write("manager: copied \(text.count) chars")
    }

    // MARK: glossary

    func reloadGlossary() {
        glossary = store.glossary()
    }

    func addGlossaryEntry(source: String, target: String) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return }
        _ = store.addGlossaryEntry(source: trimmedSource, target: trimmedTarget)
        reloadGlossary()
    }

    func deleteGlossary(_ entries: [GlossaryEntry]) {
        guard !entries.isEmpty else { return }
        store.deleteGlossaryEntries(entries)
        selectedGlossary.subtract(entries.map(\.persistentModelID))
        reloadGlossary()
    }

    func selectedEntries() -> [GlossaryEntry] {
        glossary.filter { selectedGlossary.contains($0.persistentModelID) }
    }

    func setGlossaryEnabled(_ entry: GlossaryEntry, _ enabled: Bool) {
        entry.enabled = enabled
        saveGlossary()
    }

    /// Called after an inline edit in the table.
    func glossaryEdited() {
        saveGlossary()
    }

    private func saveGlossary() {
        store.saveNow()
        reloadGlossary()
    }

    func moveGlossary(from source: IndexSet, to destination: Int) {
        var entries = glossary
        entries.move(fromOffsets: source, toOffset: destination)
        store.reorderGlossary(entries)
        reloadGlossary()
    }

    func importGlossary(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            modelNote = "CSV を読めませんでした"
            return
        }
        let rows = GlossaryCSV.parse(text)
        guard !rows.isEmpty else {
            modelNote = "CSV に読み込める行がありませんでした"
            return
        }
        store.addGlossaryEntries(rows)
        reloadGlossary()
        modelNote = "\(rows.count) 件を読み込みました"
    }

    func exportGlossary(to url: URL) {
        do {
            try store.glossaryCSV().write(to: url, atomically: true, encoding: .utf8)
            modelNote = "CSV を書き出しました"
            AppLog.write("glossary: exported to \(url.path)")
        } catch {
            modelNote = "CSV を書き出せませんでした"
            AppLog.write("glossary: export failed \(error)")
        }
    }

    // MARK: models

    func refreshInstalled() {
        var state: [String: Bool] = [:]
        for model in ModelCatalog.models {
            state[model.id] = ModelStore.isInstalled(model)
        }
        installed = state
    }

    func isInstalled(_ model: TranslationModel) -> Bool {
        installed[model.id] ?? false
    }

    func partialBytes(_ model: TranslationModel) -> Int64 {
        ModelStore.partialBytes(model)
    }

    /// Asks for the licence first (SPEC 4.4: 取得の前に PLaMo Community License を
    /// 表示し、同意を求める). Consent is remembered.
    func requestDownload(_ model: TranslationModel) {
        if AppSettings.shared.hasAcceptedLicense(for: model.id) {
            startDownload(model)
        } else {
            licenseModel = model
        }
    }

    func acceptLicense(for model: TranslationModel) {
        AppSettings.shared.acceptLicense(for: model.id)
        licenseModel = nil
        startDownload(model)
    }

    private func startDownload(_ model: TranslationModel) {
        modelNote = nil
        downloader.start(model)
        AppLog.write("manager: download requested \(model.fileName)")
    }

    func cancelDownload() {
        downloader.cancel()
    }

    private func modelFinished(_ model: TranslationModel) {
        refreshInstalled()
        modelNote = "\(model.displayName) を取得しました"
    }

    func deleteModel(_ model: TranslationModel) {
        ModelStore.delete(model)
        refreshInstalled()
        modelNote = "\(model.displayName) を削除しました"
        if AppSettings.shared.selectedModelID == model.id {
            Task { await engine.restart() }
        }
    }

    /// 「使う」: switches the model and restarts the engine (SPEC 4.4).
    func useModel(_ model: TranslationModel) {
        AppSettings.shared.selectedModelID = model.id
        AppSettings.shared.customModelPath = ""
        modelNote = "\(model.displayName) を使います"
        refreshInstalled()
        Task { await engine.restart() }
    }

    /// 「既存のファイルを使う」: keeps the original way of pointing at a local GGUF.
    func useExistingFile(_ url: URL) {
        AppSettings.shared.customModelPath = url.path
        modelNote = "\(url.lastPathComponent) を使います"
        Task { await engine.restart() }
    }

    var engineStatusText: String {
        switch engine.state {
        case .stopped: "停止中"
        case .starting: "起動中"
        case .running:
            if let label = engine.loadedModelLabel {
                "起動中（\(label)）"
            } else {
                "起動中"
            }
        case .failed(let message): "失敗: \(message)"
        }
    }

    var engineMemoryText: String {
        guard let bytes = engine.residentMemoryBytes else { return "—" }
        return ByteCount.format(Int64(clamping: bytes))
    }
}
