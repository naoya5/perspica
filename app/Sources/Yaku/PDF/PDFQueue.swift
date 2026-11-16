import AppKit
import Foundation
import Observation
import YakuCore

/// The PDF queue: one job at a time, in the order they arrived (SPEC 8.1).
///
/// Everything the surfaces show about PDFs comes from here: the panel's
/// 「作業中の PDF」 row, the menu bar icon's progress ring, the island, and the
/// manager's list. The engine is held open for the whole job (SPEC 7.1). The
/// native translator sends up to four paragraphs at a time, which is the
/// figure SPEC 7.3 measured against.
@MainActor
@Observable
final class PDFQueue {
    enum EnqueueResult {
        case accepted(PDFJob)
        case rejected(String)
    }

    /// Newest first, which is the order the manager lists them in.
    private(set) var jobs: [PDFJob] = []
    private(set) var runningID: UUID?
    /// Set when a job finishes successfully, for the island's done state.
    private(set) var recentlyFinished: PDFJob?
    private(set) var recentlyFailed: PDFJob?

    var onProgress: ((PDFJob) -> Void)?
    var onFinished: ((PDFJob) -> Void)?
    /// Called with the message when a file is turned away (SPEC 8.1).
    var onRejected: ((String) -> Void)?
    /// Picks the target language for a detected source language. The app
    /// delegate wires this to the same rule the panel uses; without it the
    /// SPEC 5.1 default applies (Japanese to English, everything else to
    /// Japanese).
    var resolveTarget: ((String) -> String)?

    private let store: TranslationStore
    private let engine: EngineManager

    private var jobTask: Task<Void, Never>?
    private var tempDirectory: URL?
    private var pagesByJob: [UUID: String] = [:]
    private var cancelledJobID: UUID?
    private var progressGate = PDFProgressGate()
    private var makeDual = true

    init(store: TranslationStore, engine: EngineManager) {
        self.store = store
        self.engine = engine
        reload()
        closeJobsLeftByLastSession()
    }

    /// A job still marked running or queued at launch belongs to a session that
    /// ended part-way (quit, crash). Its task is gone, so without this it read
    /// 「処理中」 forever; closing it as failed lets 「もう一度」 run it again.
    private func closeJobsLeftByLastSession() {
        let stale = jobs.filter { $0.jobState == .running || $0.jobState == .queued }
        guard !stale.isEmpty else { return }
        for job in stale {
            job.jobState = .failed
            job.errorMessage = "Perspica が終了したため中断しました"
        }
        store.saveNow()
        reload()
        AppLog.write("pdf: closed \(stale.count) job(s) left unfinished by the last session")
    }

    // MARK: reading

    var running: PDFJob? {
        guard let runningID else { return nil }
        return jobs.first { $0.id == runningID }
    }

    var activeJob: PDFJob? {
        running
            ?? jobs.first { $0.jobState == .running }
            ?? jobs.first { $0.jobState == .queued }
    }

    var hasActiveJob: Bool { activeJob != nil }

    var queuedCount: Int {
        jobs.filter { $0.jobState == .queued }.count
    }

    func reload() {
        jobs = store.pdfJobs()
    }

    // MARK: intake

    /// Validates the file off the main actor, then queues it.
    @discardableResult
    func enqueue(url: URL, pages: String? = nil) async -> EnqueueResult {
        switch await PDFIntake.validateInBackground(url) {
        case .rejected(let message):
            AppLog.write("pdf: rejected \(url.lastPathComponent): \(message)")
            onRejected?(message)
            return .rejected(message)

        case .accepted(let accepted):
            let job = makeJob(from: accepted, pages: pages)
            AppLog.write("pdf: queued \(job.fileName) pages=\(job.pageCount)")
            startNextIfIdle()
            return .accepted(job)
        }
    }

    private func makeJob(from accepted: PDFIntake.Accepted, pages: String?) -> PDFJob {
        let job = PDFJob(
            inputBookmark: PDFIntake.bookmark(for: accepted.url),
            fileName: accepted.url.lastPathComponent,
            pageCount: accepted.pageCount,
            stage: PDFStage.preparing
        )
        if let pages, !pages.isEmpty {
            pagesByJob[job.id] = pages
        }
        store.addPDFJob(job)
        reload()
        return job
    }

    // MARK: running

    /// Claims the slot before anything is awaited: two files enqueued in the
    /// same run-loop turn must not both start the same job.
    private func startNextIfIdle() {
        guard runningID == nil else { return }
        // `jobs` is newest first, so the oldest queued job is the last match.
        guard let next = jobs.reversed().first(where: { $0.jobState == .queued }) else { return }
        runningID = next.id
        cancelledJobID = nil
        next.jobState = .running
        Task { await start(next) }
    }

    private func start(_ job: PDFJob) async {
        guard runningID == job.id else { return }

        progressGate = PDFProgressGate()
        job.jobState = .running
        job.progress = 0
        job.stage = PDFStage.preparing
        job.errorMessage = ""
        store.saveNow()
        onProgress?(job)

        // SPEC 7.1: the engine is started when a PDF arrives, and is not
        // stopped for idle time while the job runs. `finish` balances this.
        engine.beginPDFWork()
        let running = await engine.ensureRunning()
        guard runningID == job.id else {
            engine.endPDFWork()
            return
        }
        // 取り消し pressed while the engine was starting: there was no job
        // task to cancel, so the answer is read here.
        if cancelledJobID == job.id {
            finish(job, state: .cancelled, message: "")
            return
        }
        guard running else {
            let failure = TranslationCoordinator.TranslationFailure(startFailure: engine.lastStartFailure)
            finish(job, state: .failed, message: failure.message)
            return
        }

        guard let input = PDFIntake.resolve(job.inputBookmark),
              case .accepted(let accepted) = await PDFIntake.validateInBackground(input)
        else {
            finish(job, state: .failed, message: "PDF を読めませんでした")
            return
        }
        guard runningID == job.id else {
            engine.endPDFWork()
            return
        }
        if cancelledJobID == job.id {
            finish(job, state: .cancelled, message: "")
            return
        }

        let settings = AppSettings.shared
        makeDual = settings.pdfMakeDual
        let temporary = temporaryDirectory(for: job)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        tempDirectory = temporary

        // A scan has no text to read the language from; English is the most
        // common case.
        let source = accepted.sourceLanguage ?? "en"
        let target = resolveTarget?(source) ?? LanguageDetector.defaultTarget(forSource: source)
        AppLog.write("pdf: \(job.fileName) \(source) -> \(target)\(accepted.sourceLanguage == nil ? " (no text to detect; assumed)" : "")")

        let base = input.deletingPathExtension().lastPathComponent
        let mono = temporary.appendingPathComponent("\(base).\(target).pdf")
        let dual = makeDual ? temporary.appendingPathComponent("\(base).\(target).dual.pdf") : nil
        let options = NativePDFTranslator.Options(pages: pagesByJob[job.id].flatMap(PDFPageList.parse))
        let translate = paragraphTranslator(
            sourceLanguage: source,
            target: target,
            form: target == "ja" ? settings.defaultForm : nil,
            context: accepted.title,
            glossary: store.enabledGlossaryPairs()
        )
        let started = Date()
        // The translator reports from its own tasks; the stream brings each
        // report back to the main actor in order.
        let (reports, reporter) = AsyncStream<(Double, String)>.makeStream()
        Task { [weak self] in
            for await (value, stage) in reports { self?.progressed(job, value: value, stage: stage) }
        }
        jobTask = Task { [weak self] in
            defer { reporter.finish() }
            do {
                let result = try await NativePDFTranslator.translate(
                    input: input, monoOutput: mono, dualOutput: dual, options: options,
                    translate: translate,
                    progress: { value, stage in reporter.yield((value, stage)) })
                await MainActor.run { [weak self] in
                    AppLog.write("pdf: \(result.paragraphs) paragraphs, \(result.unchanged) left as they were, \(result.formulaFallbacks) formula fallback(s)")
                    self?.translated(job, mono: mono.path, dual: dual?.path ?? "",
                                     seconds: Date().timeIntervalSince(started))
                }
            } catch {
                await MainActor.run { [weak self] in self?.jobEnded(job, error: error) }
            }
        }
    }

    /// Translates one paragraph the way the panel translates a long text:
    /// sentence chunks with the previous pairs as history, at PDF priority.
    private func paragraphTranslator(
        sourceLanguage: String,
        target: String,
        form: TranslationForm?,
        context: String,
        glossary: [GlossaryPair]
    ) -> NativePDFTranslator.Translate {
        let engine = engine
        return { text in
            let chunks = TextChunker.chunks(from: text)
            var finished: [String] = []
            var pairs: [HistoryPair] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let request = PFML3.request(
                    source: chunk.text,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: target,
                    form: form,
                    context: context,
                    history: Array(pairs.suffix(PFML3.historyLimit)),
                    glossary: GlossaryFilter.relevant(glossary, in: chunk.text)
                )
                var buffer = ""
                for try await piece in await engine.stream(request, priority: .pdf) {
                    buffer += piece
                }
                let cleaned = TranslationCleanup.clean(buffer)
                finished.append(cleaned)
                pairs.append(HistoryPair(source: chunk.text, target: cleaned))
            }
            return TextChunker.join(finished, chunks: chunks)
        }
    }

    private func jobEnded(_ job: PDFJob, error: Error) {
        guard job.id == runningID else { return }
        jobTask = nil
        if cancelledJobID == job.id || error is CancellationError {
            finish(job, state: .cancelled, message: "")
            return
        }
        AppLog.write("pdf: \(job.fileName) failed: \(error)")
        let message: String
        switch error {
        case NativePDFTranslator.Failure.encrypted: message = "パスワード付きの PDF は訳せません"
        case NativePDFTranslator.Failure.unreadable: message = "PDF を読めませんでした"
        case NativePDFTranslator.Failure.noText: message = "訳せる文字が見つかりませんでした（画像だけの PDF は訳せません）"
        default: message = "PDF を訳せませんでした"
        }
        finish(job, state: .failed, message: message)
    }

    /// One folder per job, so a retry writes where the first run did and a
    /// kept output can be found again.
    private func temporaryDirectory(for job: PDFJob) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Yaku-PDF-\(job.id.uuidString)", isDirectory: true)
    }

    private func progressed(_ job: PDFJob, value: Double, stage: String) {
        guard job.id == runningID, progressGate.accepts(value: value, stage: stage) else { return }
        job.progress = min(max(value, 0), 1)
        job.stage = stage
        onProgress?(job)
    }

    /// Moves the outputs next to the source (or the chosen folder) and ends the job.
    private func translated(_ job: PDFJob, mono: String, dual: String, seconds: Double) {
        guard job.id == runningID else { return }
        jobTask = nil
        do {
            let placed = PDFOutputLocation.place(
                monoPath: mono,
                dualPath: dual,
                input: inputURL(for: job) ?? URL(fileURLWithPath: job.fileName),
                makeDual: makeDual
            )
            job.seconds = seconds
            guard let monoURL = placed.mono else {
                // No folder took the file. The translation stays in the
                // job's temporary folder, named in the message, until the job
                // is retried or deleted.
                let tried = placed.tried.map { $0.path }.joined(separator: "、")
                let kept = tempDirectory?.path ?? ""
                tempDirectory = nil
                finish(
                    job,
                    state: .failed,
                    message: "訳した PDF を保存できませんでした（試した場所: \(tried)）。訳文は \(kept) に残っています"
                )
                return
            }
            job.outputMonoPath = monoURL.path
            job.outputDualPath = placed.dual?.path ?? ""
            if makeDual, placed.dual == nil {
                let kept = tempDirectory?.path ?? ""
                tempDirectory = nil
                finish(job, state: .failed, message: "対訳 PDF を保存できませんでした。訳のみの PDF は \(monoURL.path)、残りの出力は \(kept) に残っています")
                return
            }
            finish(job, state: .done, message: "")
        }
    }

    private func inputURL(for job: PDFJob) -> URL? {
        PDFIntake.resolve(job.inputBookmark)
    }

    /// Ends the running job (or a queued one that was cancelled) and starts
    /// the next. Every path that began the job's engine work ends here, so
    /// `endPDFWork` is balanced in this one place.
    private func finish(_ job: PDFJob, state: PDFJobState, message: String) {
        job.jobState = state
        job.errorMessage = message
        if state == .done {
            job.progress = 1
            job.stage = PDFStage.writing
        }
        store.saveNow()
        if runningID == job.id {
            runningID = nil
            engine.endPDFWork()
            cleanUpTemporary()
        }
        reload()

        switch state {
        case .done:
            recentlyFinished = job
            recentlyFailed = nil
            AppLog.write("pdf: done \(job.fileName) in \(String(format: "%.1f", job.seconds))s → \(job.outputMonoPath)")
        case .failed:
            recentlyFailed = job
            AppLog.write("pdf: failed \(job.fileName): \(message)")
        case .cancelled:
            AppLog.write("pdf: cancelled \(job.fileName)")
        default:
            break
        }

        onFinished?(job)
        startNextIfIdle()
    }

    private func cleanUpTemporary() {
        guard let tempDirectory else { return }
        try? FileManager.default.removeItem(at: tempDirectory)
        self.tempDirectory = nil
    }

    // MARK: actions

    /// 取り消し: cancels the job's task, which stops between paragraphs and
    /// pages. While the engine is still starting there is no task yet; `start`
    /// reads `cancelledJobID` after the engine answers.
    func cancel(_ job: PDFJob) {
        if job.id == runningID {
            cancelledJobID = job.id
            jobTask?.cancel()
            return
        }
        guard job.jobState == .queued else { return }
        finish(job, state: .cancelled, message: "")
    }

    func retry(_ job: PDFJob) {
        guard job.id != runningID, job.jobState != .queued else { return }
        job.jobState = .queued
        job.progress = 0
        job.stage = PDFStage.preparing
        job.errorMessage = ""
        store.saveNow()
        reload()
        startNextIfIdle()
    }

    func delete(_ job: PDFJob) {
        guard job.id != runningID else { return }
        store.deletePDFJob(job)
        pagesByJob[job.id] = nil
        // An output kept after a failed placement goes with the job.
        try? FileManager.default.removeItem(at: temporaryDirectory(for: job))
        reload()
    }

    func clearRecentlyFinished() {
        recentlyFinished = nil
        recentlyFailed = nil
    }

    /// `--demo-state`: puts a job row on screen without running a job, so
    /// the panel row and the manager list can be photographed (SPEC 15).
    @discardableResult
    func applyDemoJob(
        state: PDFJobState,
        progress: Double,
        stage: String,
        fileName: String = "attention.pdf",
        pageCount: Int = 15,
        seconds: Double = 96.4,
        errorMessage: String = "PDF を訳せませんでした"
    ) -> PDFJob {
        let job = PDFJob(
            inputBookmark: Data(),
            fileName: fileName,
            outputMonoPath: state == .done ? "/tmp/attention.ja.pdf" : "",
            outputDualPath: state == .done ? "/tmp/attention.ja.対訳.pdf" : "",
            state: state,
            pageCount: pageCount,
            seconds: state == .done ? seconds : 0,
            errorMessage: state == .failed ? errorMessage : "",
            progress: progress,
            stage: stage
        )
        store.addPDFJob(job)
        reload()
        switch state {
        case .done: recentlyFinished = job
        case .failed: recentlyFailed = job
        default: break
        }
        return job
    }

    /// Used by `applicationWillTerminate`.
    func stopSynchronously() {
        jobTask?.cancel()
        jobTask = nil
        if runningID != nil { engine.endPDFWork() }
        cleanUpTemporary()
    }

    func openOutput(_ job: PDFJob, dual: Bool = false) {
        let path = dual ? job.outputDualPath : job.outputMonoPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealOutput(_ job: PDFJob) {
        let path = job.outputMonoPath.isEmpty ? job.outputDualPath : job.outputMonoPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
