import AppKit
import Foundation
import Observation
import YakuCore

/// Runs translations and owns the state each surface shows.
///
/// SPEC 7.3: only the newest dialogue request is alive. A new request cancels
/// the previous one, which closes its connection and makes llama-server stop
/// generating. The panel and the HUD each keep their own result, but only one
/// request runs at a time across both.
@MainActor
@Observable
final class TranslationCoordinator {

    // MARK: types

    enum Phase: Equatable {
        /// Nothing to translate (the panel's empty state).
        case empty
        /// The engine is loading; the panel shows 「準備しています…」.
        case preparing
        case translating
        case done
        case failed(TranslationFailure)
    }

    enum TranslationFailure: Error, Equatable {
        case modelMissing
        case engineStartFailed
        case engineStopped
        case requestFailed

        /// SPEC 13 wording.
        var message: String {
            switch self {
            case .modelMissing: "翻訳モデルがまだありません"
            case .engineStartFailed: "翻訳エンジンを起動できませんでした"
            case .engineStopped: "翻訳エンジンが止まりました。もう一度お試しください"
            case .requestFailed: "翻訳できませんでした"
            }
        }

        var showsLogButton: Bool {
            self == .engineStartFailed || self == .requestFailed
        }
    }

    enum Surface: String {
        case panel
        case hud
        case manager
        case overlay
        case pdf
    }

    /// A language pair the user picked by hand (SPEC 5.1). `source == nil`
    /// means the choice applies whatever the detected language is.
    struct ManualPair: Equatable {
        var source: String?
        var target: String
    }

    struct SurfaceState {
        var phase: Phase = .empty
        var sourceText = ""
        var translation = ""
        var elapsed: Double?
        var sourceLanguage: String?
        var targetLanguage = "ja"
        var usedCache = false
        /// Bumped when a new request replaces the previous translation, so the
        /// view can put its scroll position back to the top.
        var scrollReset = 0
        /// Bumped each time the translation is put on the clipboard, by the
        /// button or by the shortcut, so the view shows its brief copied mark
        /// either way (`copiedMark`).
        var copyCount = 0
    }

    // MARK: state

    var panel = SurfaceState()
    var hud = SurfaceState()
    var manager = SurfaceState()

    /// Both live in the settings store, so changing them in the settings window
    /// takes effect in the panel straight away.
    var form: TranslationForm {
        get { AppSettings.shared.defaultForm }
        set { AppSettings.shared.defaultForm = newValue }
    }

    var autoTranslate: Bool {
        get { AppSettings.shared.autoTranslate }
        set { AppSettings.shared.autoTranslate = newValue }
    }

    /// True while ⌥ is held; the HUD shows the source instead of the result.
    var optionDown = false

    private(set) var manualPair: ManualPair?
    /// True while the engine is being started for a request.
    var isEngineStarting: Bool { engine.state == .starting }

    /// Demo only: keep re-sending the same text so the translating state holds
    /// still for a screenshot or a CPU measurement.
    var demoRepeat = false

    // MARK: dependencies

    private let engine: EngineManager
    private let store: TranslationStore

    private var currentTask: Task<Void, Never>?
    private var currentID: UUID?
    private var currentSurface: Surface?
    private var autoTask: Task<Void, Never>?
    private var managerAutoTask: Task<Void, Never>?
    private var lastSourceLanguage: String?
    private var demoGlow = false

    /// Called when a dialogue request (panel, HUD, manager) starts. SPEC 7.3's
    /// priority is 対話 > 画面 > PDF, so the screen overlay gives way here.
    var onDialogueRequestStarted: (() -> Void)?

    /// How often streamed text is published to the panel.
    ///
    /// The first piece is published at once; after that the panel waits this
    /// long. M1-M4 published on every streamed piece, which re-laid out and
    /// redrew the whole translation dozens of times a second. M5 measured
    /// 100ms, 300ms, 500ms and 2000ms against each other and found no
    /// reproducible difference (19.3-19.8% CPU at every setting; M5.md 4.2),
    /// because the reveal's own redraw sets the cost. 300ms is kept anyway: it
    /// holds the publish rate below the reveal rate, so no layout work is done
    /// for text that cannot be seen yet.
    private static let publishInterval = Duration.milliseconds(300)

    init(engine: EngineManager, store: TranslationStore) {
        self.engine = engine
        self.store = store

        let settings = AppSettings.shared
        let target = settings.manualPairTarget
        if !target.isEmpty {
            let source = settings.manualPairSource
            manualPair = ManualPair(source: source.isEmpty ? nil : source, target: target)
        }
    }

    // MARK: panel input

    func panelTextChanged() {
        let trimmed = panel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            autoTask?.cancel()
            autoTask = nil
            cancelCurrent(reason: "panel cleared", keeping: .panel)
            panel.phase = .empty
            panel.translation = ""
            panel.elapsed = nil
            panel.usedCache = false
            return
        }
        scheduleAutoTranslate()
    }

    private func scheduleAutoTranslate() {
        autoTask?.cancel()
        guard autoTranslate else { return }
        let text = panel.sourceText
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.panel.sourceText == text else { return }
            self.translatePanel()
        }
    }

    /// ⌘↩ or the debounce: translate what is in the panel's source field.
    func translatePanel(context: String? = nil, frontApp: String? = nil) {
        autoTask?.cancel()
        autoTask = nil
        start(surface: .panel, text: panel.sourceText, context: context, frontApp: frontApp)
    }

    func retryPanel() {
        translatePanel()
    }

    /// Puts a surface's translation on the clipboard: its copy button, ⌘⇧C in
    /// the panel and ⌘C in the HUD. The button and the key share this, so both
    /// bump `copyCount` and show the same mark.
    func copyTranslation(on surface: Surface) {
        let text = state(for: surface).translation
        guard Clipboard.copy(text) else { return }
        mutate(surface) { $0.copyCount += 1 }
        AppLog.write("\(surface.rawValue) copy \(text.count) chars")
    }

    /// Used by the HUD's 「パネルで開く」 (⌘O).
    func openInPanel(source: String) {
        autoTask?.cancel()
        autoTask = nil
        panel.sourceText = source
        panel.phase = .empty
        panel.translation = ""
        panel.elapsed = nil
        translatePanel()
    }

    // MARK: HUD input

    func translateHUD(text: String, context: String?, frontApp: String?) {
        hud.sourceText = text
        start(surface: .hud, text: text, context: context, frontApp: frontApp)
    }

    /// Tab in the HUD: switch the style and translate the selection again.
    func toggleFormAndRetranslateHUD() {
        setForm(form == .plain ? .polite : .plain)
        guard !hud.sourceText.isEmpty else { return }
        translateHUD(text: hud.sourceText, context: nil, frontApp: nil)
    }

    func retryHUD() {
        guard !hud.sourceText.isEmpty else { return }
        translateHUD(text: hud.sourceText, context: nil, frontApp: nil)
    }

    func dismissHUD() {
        cancelCurrent(reason: "hud dismissed", keeping: nil)
        hud.phase = .empty
        hud.translation = ""
        hud.elapsed = nil
        hud.sourceText = ""
        hud.usedCache = false
    }

    // MARK: manager input (SPEC 4.4)

    /// ⌘↩ or the toolbar's 訳す button in the manager window.
    func translateManager() {
        managerAutoTask?.cancel()
        managerAutoTask = nil
        start(surface: .manager, text: manager.sourceText, context: nil, frontApp: nil)
    }

    func retryManager() {
        translateManager()
    }

    func managerTextChanged() {
        let trimmed = manager.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            managerAutoTask?.cancel()
            managerAutoTask = nil
            cancelCurrent(reason: "manager cleared", keeping: .manager)
            manager.phase = .empty
            manager.translation = ""
            manager.elapsed = nil
            manager.usedCache = false
            return
        }
        managerAutoTask?.cancel()
        guard autoTranslate else { return }
        let text = manager.sourceText
        managerAutoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.manager.sourceText == text else { return }
            self.translateManager()
        }
    }

    /// 「用語集に足す」 in the history view (SPEC 4.4).
    func addGlossaryEntry(source: String, target: String) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else { return }
        _ = store.addGlossaryEntry(source: trimmedSource, target: trimmedTarget)
        AppLog.write("glossary: added \(trimmedSource) → \(trimmedTarget) from history")
    }

    // MARK: preferences

    func setForm(_ newValue: TranslationForm) {
        form = newValue
        AppSettings.shared.defaultForm = newValue
    }

    /// Choosing a language by hand remembers the pair (SPEC 5.1).
    func setManualTarget(_ code: String, forSource source: String?) {
        let pair = ManualPair(source: source, target: code)
        manualPair = pair
        let settings = AppSettings.shared
        settings.manualPairTarget = pair.target
        settings.manualPairSource = pair.source ?? ""
        AppLog.write("language: manual pair \(pair.source ?? "any") -> \(pair.target)")

        if !panel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.targetLanguage = resolvedTarget(forSource: panel.sourceLanguage)
            translatePanel()
        }
        if !hud.sourceText.isEmpty {
            translateHUD(text: hud.sourceText, context: nil, frontApp: nil)
        }
    }

    /// The 「自動（原文を判定）」 menu entry: forget the manual pair.
    func clearManualPair() {
        manualPair = nil
        let settings = AppSettings.shared
        settings.manualPairTarget = ""
        settings.manualPairSource = ""
        AppLog.write("language: manual pair cleared")
        if !panel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.targetLanguage = resolvedTarget(forSource: panel.sourceLanguage)
            translatePanel()
        }
    }

    /// ⌘D: swap the direction and the two texts. The new source is translated
    /// by the ordinary auto-translate debounce.
    func swapLanguages() {
        let oldSource = panel.sourceLanguage ?? LanguageDetector.defaultTarget(forSource: panel.targetLanguage)
        let oldTarget = panel.targetLanguage

        cancelCurrent(reason: "swap", keeping: nil)

        let pair = ManualPair(source: oldTarget, target: oldSource)
        manualPair = pair
        let settings = AppSettings.shared
        settings.manualPairTarget = pair.target
        settings.manualPairSource = pair.source ?? ""

        let oldText = panel.sourceText
        panel.sourceText = panel.translation
        panel.translation = oldText
        panel.sourceLanguage = oldTarget
        panel.targetLanguage = oldSource
        // The swapped-in text is in the old target language; without this a
        // short one fell back to the language it was translated from.
        lastSourceLanguage = oldTarget
        panel.phase = panel.translation.isEmpty ? .empty : .done
        panel.elapsed = nil
        AppLog.write("language: swapped to \(oldTarget) -> \(oldSource)")
    }

    func resolvedTarget(forSource source: String?) -> String {
        if let pair = manualPair, pair.source == nil || pair.source == source {
            return pair.target
        }
        return LanguageDetector.defaultTarget(forSource: source)
    }

    // MARK: demo hooks

    func applyDemoFailure(_ failure: TranslationFailure) {
        panel.phase = .failed(failure)
        panel.translation = ""
        panel.elapsed = nil
    }

    /// `--demo-glow`: hold the processing light on without translating.
    func applyDemoGlow() {
        demoGlow = true
        panel.phase = .translating
        panel.translation = ""
        panel.elapsed = nil
        AppLog.write("demo: glow only")
    }

    // MARK: the request

    private func start(surface: Surface, text: String, context: String?, frontApp: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if surface == .panel {
                panel.phase = .empty
                panel.translation = ""
                panel.elapsed = nil
            }
            if surface == .manager {
                manager.phase = .empty
                manager.translation = ""
                manager.elapsed = nil
            }
            return
        }

        // SPEC 7.3: the dialogue comes before the screen overlay, so any
        // overlay request in flight is given up.
        onDialogueRequestStarted?()

        cancelCurrent(reason: "new request on \(surface.rawValue)", keeping: surface)

        let id = UUID()
        currentID = id
        currentSurface = surface

        // Leave the previous translation on screen until the new one produces
        // its first character, so typing does not flash the empty state.
        mutate(surface) { state in
            state.elapsed = nil
            state.usedCache = false
            state.phase = engine.isRunning ? .translating : .preparing
            state.scrollReset += 1
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, surface: surface, text: trimmed, context: context, frontApp: frontApp)
        }
        currentTask = task
    }

    /// Cancels the in-flight request. `keeping` is the surface that is about to
    /// be replaced; the other one is reset because its request is gone.
    private func cancelCurrent(reason: String, keeping: Surface?) {
        guard let task = currentTask else { return }
        let interrupted = currentSurface
        AppLog.write("translate: cancel \(interrupted?.rawValue ?? "?") request (\(reason))")
        task.cancel()
        currentTask = nil
        currentID = nil
        currentSurface = nil

        guard let interrupted, interrupted != keeping else { return }
        switch interrupted {
        case .panel:
            if panel.phase == .translating || panel.phase == .preparing {
                panel.phase = .empty
                panel.translation = ""
            }
        case .hud:
            if hud.phase == .translating || hud.phase == .preparing {
                hud.phase = .empty
                hud.translation = ""
            }
        case .manager:
            if manager.phase == .translating || manager.phase == .preparing {
                manager.phase = .empty
                manager.translation = ""
            }
        default:
            break
        }
    }

    private func run(
        id: UUID,
        surface: Surface,
        text: String,
        context: String?,
        frontApp: String?
    ) async {
        let started = CFAbsoluteTimeGetCurrent()

        let sourceLanguage = LanguageDetector.resolve(text: text, previous: lastSourceLanguage)
        if let sourceLanguage { lastSourceLanguage = sourceLanguage }
        let target = resolvedTarget(forSource: sourceLanguage)
        let chunks = TextChunker.chunks(from: text)
        // SPEC 5.2: only the enabled glossary entries that appear in the source
        // are sent, and this applies to every entry point (panel, HUD, manager).
        let glossary = GlossaryFilter.relevant(store.enabledGlossaryPairs(), in: text)
        let formValue: TranslationForm? = target == "ja" ? form : nil
        let model = ModelStore.cacheKey()

        mutate(surface) { state in
            state.sourceLanguage = sourceLanguage
            state.targetLanguage = target
        }
        AppLog.write("translate start id=\(shortID(id)) surface=\(surface.rawValue) "
            + "chars=\(text.count) chunks=\(chunks.count) source=\(sourceLanguage ?? "?") "
            + "target=\(target) form=\(formValue?.rawValue ?? "-") context=\(context?.count ?? 0)ch "
            + "glossary=\(glossary.count) model=\(model)")

        let cacheKey = chunks.count == 1
            ? CacheKey.key(
                source: text,
                context: context,
                glossary: glossary,
                sourceLanguage: sourceLanguage,
                targetLanguage: target,
                form: formValue,
                model: model
            )
            : nil

        // A demo repeat must actually stream, so it ignores the cache.
        if let cacheKey, !demoRepeat, let hit = store.cached(key: cacheKey) {
            guard currentID == id else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            mutate(surface) { state in
                state.translation = hit
                state.elapsed = elapsed
                state.phase = .done
                state.usedCache = true
            }
            record(surface: surface, source: text, translation: hit, sourceLanguage: sourceLanguage,
                   target: target, form: formValue, frontApp: frontApp, seconds: elapsed)
            AppLog.write(String(format: "translate done id=%@ cache=hit in %.3fs", shortID(id), elapsed))
            return
        }

        var attempt = 0
        while true {
            guard currentID == id else { return }

            if !engine.isRunning {
                mutate(surface) { $0.phase = .preparing }
            }
            guard await engine.ensureRunning() else {
                guard currentID == id else { return }
                let failure: TranslationFailure = engine.lastStartFailure == .modelMissing
                    ? .modelMissing : .engineStartFailed
                mutate(surface) { $0.phase = .failed(failure) }
                AppLog.write("translate failed id=\(shortID(id)) engine start (\(String(describing: engine.lastStartFailure)))")
                return
            }
            guard currentID == id else { return }
            mutate(surface) { $0.phase = .translating }
            engine.markUsed()

            do {
                let pairs = try await stream(
                    id: id,
                    surface: surface,
                    chunks: chunks,
                    sourceLanguage: sourceLanguage,
                    target: target,
                    form: formValue,
                    context: context,
                    glossary: glossary,
                    started: started
                )
                guard currentID == id else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                // A demo repeat holds the translating state (light on, partial
                // text) instead of settling, so a screenshot and a CPU
                // measurement both get a stable frame.
                mutate(surface) { state in
                    state.phase = demoRepeat ? .translating : .done
                    state.elapsed = demoRepeat ? nil : elapsed
                }
                let final = state(for: surface).translation
                if let cacheKey, !demoRepeat { store.store(key: cacheKey, target: final) }
                record(surface: surface, source: text, translation: final, sourceLanguage: sourceLanguage,
                       target: target, form: formValue, frontApp: frontApp, seconds: elapsed)
                AppLog.write(String(format: "translate done id=%@ in %.3fs pairs=%d", shortID(id), elapsed, pairs.count))
                if demoRepeat, surface == .panel, currentID == id {
                    // Repeat the first chunk, so the visible text stays short
                    // and the light keeps turning.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard currentID == id else { return }
                    start(surface: .panel, text: chunks[0].text, context: context, frontApp: frontApp)
                }
                return
            } catch is CancellationError {
                AppLog.write("translate cancelled id=\(shortID(id))")
                return
            } catch {
                if Task.isCancelled {
                    AppLog.write("translate cancelled id=\(shortID(id))")
                    return
                }
                // SPEC 7.1: if the engine died on its own, start it once more
                // and retry; a second failure is reported.
                if attempt == 0, !engine.isRunning {
                    attempt += 1
                    AppLog.write("translate: engine died mid-request id=\(shortID(id)); restarting once")
                    engine.acknowledgeCrash()
                    mutate(surface) { state in
                        state.phase = .preparing
                        state.translation = ""
                    }
                    continue
                }
                guard currentID == id else { return }
                let failure: TranslationFailure = engine.isRunning ? .requestFailed : .engineStopped
                mutate(surface) { $0.phase = .failed(failure) }
                AppLog.write("translate failed id=\(shortID(id)) \(error)")
                return
            }
        }
    }

    /// Streams every chunk in order, carrying the previous two pairs as
    /// translation history (SPEC 7.4).
    private func stream(
        id: UUID,
        surface: Surface,
        chunks: [TextChunk],
        sourceLanguage: String?,
        target: String,
        form: TranslationForm?,
        context: String?,
        glossary: [GlossaryPair],
        started: CFAbsoluteTime
    ) async throws -> [HistoryPair] {
        var finished: [String] = []
        var pairs: [HistoryPair] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard let client = engine.client else { throw TranslationFailure.engineStopped }

            // The glossary was narrowed against the whole text; narrow it again
            // per chunk so a chunk only carries the terms it contains.
            let chunkGlossary = GlossaryFilter.relevant(glossary, in: chunk.text)
            let prompt = PFML3.prompt(
                source: chunk.text,
                sourceLanguage: sourceLanguage,
                targetLanguage: target,
                form: form,
                context: context,
                history: Array(pairs.suffix(PFML3.historyLimit)),
                glossary: chunkGlossary
            )
            let request = CompletionRequest(prompt: prompt, source: chunk.text)
            AppLog.write("translate chunk \(index + 1)/\(chunks.count) id=\(shortID(id)) "
                + "chars=\(chunk.text.count) history=\(min(pairs.count, PFML3.historyLimit)) "
                + "glossary=\(chunkGlossary.count)")

            var buffer = ""
            // Published once per chunk so the log shows how long the first
            // character took (SPEC 14: PDF の処理中でも待たされないこと).
            var loggedFirstPiece = false
            // Publishing re-lays out and redraws the whole translation, so
            // publishing on every streamed piece spends CPU in proportion to
            // the model's speed rather than to what the eye can follow (SPEC
            // 14, M5.md 4.2). The first piece is published at once, so the
            // text starts to appear as soon as the engine answers; later
            // pieces wait for the interval.
            var lastPublish = ContinuousClock.now - Self.publishInterval
            for try await piece in client.stream(request) {
                if !loggedFirstPiece, !piece.isEmpty {
                    loggedFirstPiece = true
                    AppLog.write(String(
                        format: "translate first piece id=%@ surface=%@ in %.3fs",
                        shortID(id), surface.rawValue, CFAbsoluteTimeGetCurrent() - started
                    ))
                }
                if Task.isCancelled { throw CancellationError() }
                buffer += piece
                let now = ContinuousClock.now
                guard now - lastPublish >= Self.publishInterval else { continue }
                lastPublish = now
                let joined = TextChunker.join(finished + [buffer], chunks: chunks)
                mutate(surface) { $0.translation = joined }
            }
            let cleaned = TranslationCleanup.clean(buffer)
            finished.append(cleaned)
            pairs.append(HistoryPair(source: chunk.text, target: cleaned))
            mutate(surface) { $0.translation = TextChunker.join(finished, chunks: chunks) }
        }
        return pairs
    }

    // MARK: helpers

    private func state(for surface: Surface) -> SurfaceState {
        switch surface {
        case .hud: hud
        case .manager: manager
        default: panel
        }
    }

    private func mutate(_ surface: Surface, _ body: (inout SurfaceState) -> Void) {
        switch surface {
        case .hud: body(&hud)
        case .manager: body(&manager)
        default: body(&panel)
        }
    }

    /// The model name shown in the panel's status line (SPEC 4.2).
    var modelDisplayName: String {
        ModelCatalog.model(id: AppSettings.shared.selectedModelID)?.shortName ?? "PLaMo 0.8B"
    }

    private func record(
        surface: Surface,
        source: String,
        translation: String,
        sourceLanguage: String?,
        target: String,
        form: TranslationForm?,
        frontApp: String?,
        seconds: Double
    ) {
        guard !translation.isEmpty, !demoRepeat, !demoGlow else { return }
        guard AppSettings.shared.keepHistory else { return }
        store.addHistory(HistoryItem(
            date: Date(),
            origin: surface.rawValue,
            source: source,
            target: translation,
            sourceLanguage: sourceLanguage ?? "",
            targetLanguage: target,
            form: form?.rawValue ?? "",
            frontApp: frontApp ?? "",
            model: EngineManager.modelName,
            seconds: seconds
        ))
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
