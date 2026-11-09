import AppKit
import Foundation
import Observation
import YakuCore

/// The PDF queue: one job at a time, in the order they arrived (SPEC 8.1).
///
/// Everything the surfaces show about PDFs comes from here: the panel's
/// 「作業中の PDF」 row, the menu bar icon's progress ring, the island, and the
/// manager's list. The engine is held open for the whole job (SPEC 7.1) and the
/// worker is limited to three parallel paragraphs so a panel translation still
/// has a slot (SPEC 7.3).
@MainActor
@Observable
final class PDFQueue {
    enum EnqueueResult {
        case accepted(PDFJob)
        /// No worker yet: the caller should ask before installing (SPEC 8.2).
        case needsWorker
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

    let installer = PDFWorkerInstaller()

    private let store: TranslationStore
    private let engine: EngineManager

    private var worker: PDFWorkerProcess?
    private var tempDirectory: URL?
    private var pagesByJob: [UUID: String] = [:]
    private var didFinish = false
    private var lastError = ""
    private var cancelledJobID: UUID?
    private var pendingIntake: PDFIntake.Accepted?
    /// The `--pages` range that arrived with `pendingIntake`, so it is not lost
    /// while the worker is being installed.
    private var pendingPages: String?
    private var lastDeliveredProgress = -1.0
    private var lastDeliveredStage = ""

    init(store: TranslationStore, engine: EngineManager) {
        self.store = store
        self.engine = engine
        reload()
        closeJobsLeftByLastSession()
    }

    /// A job still marked running or queued at launch belongs to a session that
    /// ended part-way (quit, crash). Its worker is gone, so without this it read
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

    @discardableResult
    func enqueue(url: URL, pages: String? = nil) -> EnqueueResult {
        switch PDFIntake.validate(url) {
        case .rejected(let message):
            AppLog.write("pdf: rejected \(url.lastPathComponent): \(message)")
            onRejected?(message)
            return .rejected(message)

        case .accepted(let accepted):
            guard PDFWorkerPaths.pythonExecutable != nil else {
                AppLog.write("pdf: worker not installed; asking")
                pendingIntake = accepted
                pendingPages = pages
                return .needsWorker
            }
            let job = makeJob(from: accepted, pages: pages)
            AppLog.write("pdf: queued \(job.fileName) pages=\(job.pageCount)")
            startNextIfIdle()
            return .accepted(job)
        }
    }

    /// Called after the installer finishes successfully, to run the file that
    /// started the whole thing (SPEC 8.2).
    func runPendingIntake() {
        guard let accepted = pendingIntake else { return }
        pendingIntake = nil
        let pages = pendingPages
        pendingPages = nil
        let job = makeJob(from: accepted, pages: pages)
        AppLog.write("pdf: queued after install \(job.fileName)")
        startNextIfIdle()
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

    private func startNextIfIdle() {
        guard runningID == nil else { return }
        // `jobs` is newest first, so the oldest queued job is the last match.
        guard let next = jobs.reversed().first(where: { $0.jobState == .queued }) else { return }
        Task { await start(next) }
    }

    private func start(_ job: PDFJob) async {
        guard let python = PDFWorkerPaths.pythonExecutable,
              let script = PDFWorkerPaths.translateScript
        else {
            finish(job, state: .failed, message: "PDF ワーカーがありません")
            return
        }

        runningID = job.id
        cancelledJobID = nil
        didFinish = false
        lastError = ""
        lastDeliveredProgress = -1
        lastDeliveredStage = ""
        job.jobState = .running
        job.progress = 0
        job.stage = PDFStage.preparing
        job.errorMessage = ""
        store.saveNow()
        onProgress?(job)

        // SPEC 7.1: the engine is started when a PDF arrives, and is not
        // stopped for idle time while the job runs.
        engine.beginPDFWork()
        let running = await engine.ensureRunning()
        guard let port = engine.port, let key = engine.apiKey, running else {
            engine.endPDFWork()
            finish(job, state: .failed, message: "翻訳エンジンを起動できませんでした")
            return
        }
        guard runningID == job.id else {
            engine.endPDFWork()
            return
        }

        guard let input = PDFIntake.resolve(job.inputBookmark),
              case .accepted(let accepted) = PDFIntake.validate(input)
        else {
            engine.endPDFWork()
            finish(job, state: .failed, message: "PDF を読めませんでした")
            return
        }

        let settings = AppSettings.shared
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yaku-PDF-\(job.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        tempDirectory = temporary

        let glossaryPath = writeGlossary(store.enabledGlossaryPairs(), into: temporary)

        var arguments = [
            script.path,
            input.path,
            "--engine-url", "http://127.0.0.1:\(port)",
            "--output", temporary.path,
            "--lang-in", "en",
            "--lang-out", settings.defaultTargetLanguage,
        ]
        if settings.defaultTargetLanguage == "ja" {
            arguments += ["--form", settings.defaultForm.rawValue]
        }
        arguments += ["--context", accepted.title]
        if let glossaryPath { arguments += ["--glossary", glossaryPath] }
        if let pages = pagesByJob[job.id] { arguments += ["--pages", pages] }

        let process = PDFWorkerProcess()
        process.onEvent = { [weak self] event in self?.handle(event, job: job) }
        process.onExit = { [weak self] status in self?.handleExit(status: status, job: job) }
        worker = process

        do {
            try process.start(
                executable: python,
                arguments: arguments,
                environment: ["YAKU_ENGINE_API_KEY": key]
            )
        } catch {
            engine.endPDFWork()
            finish(job, state: .failed, message: "PDF ワーカーを起動できませんでした")
        }
    }

    private func writeGlossary(_ pairs: [GlossaryPair], into directory: URL) -> String? {
        guard !pairs.isEmpty else { return nil }
        let rows = pairs.map { ["source": $0.source, "target": $0.target] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) else {
            return nil
        }
        let url = directory.appendingPathComponent("glossary.json")
        try? data.write(to: url)
        return url.path
    }

    private func handle(_ event: PDFWorkerEvent, job: PDFJob) {
        guard job.id == runningID else { return }
        switch event {
        case .progress(let value, let stage):
            job.progress = min(max(value, 0), 1)
            job.stage = stage
            // BabelDOC reports progress many times a second; the surfaces only
            // need a step change.
            let changed = abs(job.progress - lastDeliveredProgress) >= 0.01 || stage != lastDeliveredStage
            lastDeliveredProgress = job.progress
            lastDeliveredStage = stage
            if changed { onProgress?(job) }

        case .done(let mono, let dual, let seconds):
            didFinish = true
            let placed = PDFOutputLocation.place(
                monoPath: mono,
                dualPath: dual,
                input: inputURL(for: job) ?? URL(fileURLWithPath: job.fileName),
                makeDual: AppSettings.shared.pdfMakeDual
            )
            job.outputMonoPath = placed.mono?.path ?? ""
            job.outputDualPath = placed.dual?.path ?? ""
            job.seconds = seconds
            finish(job, state: .done, message: "")

        case .error(let message):
            lastError = message
        }
    }

    private func handleExit(status: Int32, job: PDFJob) {
        worker = nil
        guard job.id == runningID else { return }
        if didFinish { return }
        if cancelledJobID == job.id {
            finish(job, state: .cancelled, message: "")
            return
        }
        let message = lastError.isEmpty
            ? "PDF を訳せませんでした（終了コード \(status)）"
            : lastError
        finish(job, state: .failed, message: message)
    }

    private func inputURL(for job: PDFJob) -> URL? {
        PDFIntake.resolve(job.inputBookmark)
    }

    private func finish(_ job: PDFJob, state: PDFJobState, message: String) {
        job.jobState = state
        job.errorMessage = message
        if state == .done {
            job.progress = 1
            job.stage = PDFStage.writing
        }
        store.saveNow()
        runningID = nil
        engine.endPDFWork()
        cleanUpTemporary()
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

    /// 取り消し: SIGTERM, then SIGKILL after three seconds (SPEC 8.2).
    func cancel(_ job: PDFJob) {
        if job.id == runningID {
            cancelledJobID = job.id
            Task { await worker?.terminate() }
            return
        }
        guard job.jobState == .queued else { return }
        finish(job, state: .cancelled, message: "")
    }

    func retry(_ job: PDFJob) {
        guard !hasActiveJob || job.id == runningID else {
            // Still queued behind another job.
            return
        }
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
        reload()
    }

    func clearRecentlyFinished() {
        recentlyFinished = nil
        recentlyFailed = nil
    }

    /// `--demo-state`: puts a job row on screen without running the worker, so
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
        worker?.terminateSynchronously()
        worker = nil
        engine.endPDFWork()
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
