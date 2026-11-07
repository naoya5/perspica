import Foundation
import YakuCore

/// Translates the blocks read off one screen (SPEC 9 の訳, SPEC 5.2 の F4).
///
/// The specification's order: at most three requests in flight, started in
/// reading order (top to bottom). Each block is translated on its own, with the
/// other blocks of the same screen as context, and carries the glossary and the
/// cache from M1/M2.
///
/// Priority (SPEC 7.3): the dialogue surfaces come first, so this translator is
/// cancelled as soon as a new panel or HUD request starts. It never cancels a
/// dialogue request itself.
@MainActor
final class OverlayTranslator {
    /// SPEC 9: 最大 3 件を同時に.
    static let maximumConcurrent = 3

    /// Called on the main actor as each block's translation arrives.
    var onTranslation: ((Int, String) -> Void)?
    /// Called once, when the last block has finished or the run was cancelled.
    var onFinished: ((Bool) -> Void)?

    private let engine: EngineManager
    private let store: TranslationStore

    private var workers: [Task<Void, Never>] = []
    private var generation = 0
    private(set) var isRunning = false

    init(engine: EngineManager, store: TranslationStore) {
        self.engine = engine
        self.store = store
    }

    /// Starts a run. Any run already going is cancelled first.
    func start(blocks: [OCRBlock]) {
        cancel(notify: false)
        guard !blocks.isEmpty else {
            onFinished?(true)
            return
        }
        generation += 1
        let token = generation
        isRunning = true

        let settings = AppSettings.shared
        let texts = blocks.map(\.text)
        // The target language follows the screen as a whole, so one short block
        // cannot be read as a different language (SPEC 5.1).
        let detected = LanguageDetector.detect(texts.joined(separator: " "))
        let sourceLanguage = detected.code
        let target = LanguageDetector.defaultTarget(forSource: sourceLanguage)
        let form: TranslationForm? = target == "ja" ? settings.defaultForm : nil
        let model = ModelStore.cacheKey()

        AppLog.write("overlay: translating \(blocks.count) block(s) "
            + "source=\(sourceLanguage ?? "?") target=\(target) "
            + "form=\(form?.rawValue ?? "-") model=\(model)")

        let started = CFAbsoluteTimeGetCurrent()
        let total = blocks.count
        var remaining = total
        // A shared cursor: three workers pull the next block in reading order,
        // so a slow block does not hold up the ones behind it.
        var cursor = 0

        func finishOne() {
            remaining -= 1
            guard remaining == 0 else { return }
            guard token == generation else { return }
            isRunning = false
            let seconds = CFAbsoluteTimeGetCurrent() - started
            AppLog.write(String(format: "overlay: all %d block(s) translated in %.3fs", total, seconds))
            onFinished?(true)
        }

        for _ in 0..<min(Self.maximumConcurrent, total) {
            let task = Task { [weak self] in
                guard let self else { return }
                while true {
                    guard token == self.generation else { return }
                    let index = cursor
                    guard index < total else { return }
                    cursor += 1

                    let block = blocks[index]
                    let context = OverlayContext.context(forIndex: index, in: texts)
                    let glossary = GlossaryFilter.relevant(self.store.enabledGlossaryPairs(), in: block.text)
                    let translation = await self.translate(
                        block: block,
                        index: index,
                        context: context.isEmpty ? nil : context,
                        sourceLanguage: sourceLanguage,
                        target: target,
                        form: form,
                        glossary: glossary,
                        model: model
                    )
                    guard token == self.generation else { return }
                    if let translation {
                        self.onTranslation?(index, translation)
                    }
                    finishOne()
                }
            }
            workers.append(task)
        }
    }

    /// Stops every in-flight request (their connections close, which makes
    /// llama-server stop generating).
    func cancel(notify: Bool = true) {
        guard isRunning || !workers.isEmpty else { return }
        generation += 1
        for task in workers { task.cancel() }
        workers = []
        isRunning = false
        AppLog.write("overlay: translation cancelled")
        if notify { onFinished?(false) }
    }

    // MARK: one block

    private func translate(
        block: OCRBlock,
        index: Int,
        context: String?,
        sourceLanguage: String?,
        target: String,
        form: TranslationForm?,
        glossary: [GlossaryPair],
        model: String
    ) async -> String? {
        let text = block.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let blockStarted = CFAbsoluteTimeGetCurrent()

        let cacheKey = CacheKey.key(
            source: text,
            context: context,
            glossary: glossary,
            sourceLanguage: sourceLanguage,
            targetLanguage: target,
            form: form,
            model: model
        )
        if let hit = store.cached(key: cacheKey) {
            AppLog.write("overlay: block \(index) cache=hit")
            record(text: text, translation: hit, sourceLanguage: sourceLanguage, target: target,
                   form: form, seconds: CFAbsoluteTimeGetCurrent() - blockStarted)
            return hit
        }

        // The engine is started before the capture when the hotkey is pressed,
        // but the first block can arrive before /health is 200.
        guard await engine.ensureRunning(), let client = engine.client else {
            AppLog.write("overlay: engine unavailable for block \(index)")
            return nil
        }
        engine.markUsed()

        let chunks = TextChunker.chunks(from: text)
        var finished: [String] = []
        var pairs: [HistoryPair] = []
        do {
            for (chunkIndex, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
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
                var buffer = ""
                for try await piece in client.stream(request) {
                    if Task.isCancelled { throw CancellationError() }
                    buffer += piece
                }
                let cleaned = TranslationCleanup.clean(buffer)
                finished.append(cleaned)
                pairs.append(HistoryPair(source: chunk.text, target: cleaned))
                if chunkIndex == 0 {
                    AppLog.write("overlay: block \(index) first chunk done (\(text.count) chars)")
                }
            }
        } catch {
            AppLog.write("overlay: block \(index) failed: \(error)")
            return nil
        }

        let joined = TextChunker.join(finished, chunks: chunks)
        guard !joined.isEmpty else { return nil }
        if chunks.count == 1 { store.store(key: cacheKey, target: joined) }
        record(text: text, translation: joined, sourceLanguage: sourceLanguage, target: target,
               form: form, seconds: CFAbsoluteTimeGetCurrent() - blockStarted)
        return joined
    }

    /// One history row per block, with the overlay origin (SPEC 5.3, 11).
    private func record(
        text: String,
        translation: String,
        sourceLanguage: String?,
        target: String,
        form: TranslationForm?,
        seconds: Double
    ) {
        guard AppSettings.shared.keepHistory else { return }
        store.addHistory(HistoryItem(
            date: Date(),
            origin: "overlay",
            source: text,
            target: translation,
            sourceLanguage: sourceLanguage ?? "",
            targetLanguage: target,
            form: form?.rawValue ?? "",
            frontApp: "",
            model: EngineManager.modelName,
            seconds: seconds
        ))
    }
}
