import Darwin
import Foundation
import YakuCore

/// Runs `translate_pdf.py` and turns its stdout into events (SPEC 8.2).
///
/// The worker is put into its own process group by the Python side, so a cancel
/// can signal the whole group: the per-paragraph translator processes that
/// pdf2zh-next starts die with it instead of being left behind.
///
/// Lines and the exit are delivered in order. The worker writes its `done`
/// line and returns at once, so the pipe's last read and the termination
/// callback fire within microseconds of each other on different threads.
/// Every line is queued on the main queue, which is FIFO, and the exit is only
/// queued after the pipe reached end of file (or, if a grandchild keeps the
/// pipe open, after a grace period), so a finished job is never reported as
/// an exit without its result.
@MainActor
final class PDFWorkerProcess {
    private var process: Process?
    private(set) var pid: pid_t?
    private nonisolated let splitter = LineSplitter()

    var onEvent: ((PDFWorkerEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    /// How long the exit may wait for the pipe's end of file.
    private nonisolated static let exitGrace: TimeInterval = 5

    func start(executable: URL, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        // SPEC 11: pdf.log rotates at 5 MB during a job too, so the app writes
        // it rather than the worker.
        AppLog.rotateIfNeeded(AppPaths.pdfLog)
        process.standardError = AppLog.rotatingPipe(for: AppPaths.pdfLog)

        let pipe = Pipe()
        process.standardOutput = pipe
        let splitter = self.splitter
        let join = ExitJoin()

        // The readability handler runs on one serial queue, so the reads come in
        // order; the empty read is end of file.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if let status = join.reachedEndOfFile() {
                    Self.queueExit(self, status: status)
                }
                return
            }
            let lines = splitter.feed(data)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(lines) }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let pid = finished.processIdentifier
            if join.exited(status: status) {
                Self.queueExit(self, status: status)
                return
            }
            let worker = self
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) {
                guard join.forceExit() else { return }
                AppLog.write("pdf: worker pid=\(pid) exited but its pipe stayed open; reporting the exit")
                Self.queueExit(worker, status: status)
            }
        }

        try process.run()
        self.process = process
        self.pid = process.processIdentifier
        // The arguments carry the input path and the document title, which do
        // not belong in the log.
        AppLog.write("pdf: worker started pid=\(process.processIdentifier) script=\(URL(fileURLWithPath: arguments.first ?? "").lastPathComponent)")
    }

    private nonisolated static func queueExit(_ worker: PDFWorkerProcess?, status: Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { worker?.exited(status: status) }
        }
    }

    /// SIGTERM to the group, then SIGKILL after three seconds (SPEC 8.2).
    func terminate() async {
        guard let pid, process?.isRunning == true else { return }
        AppLog.write("pdf: cancelling worker pid=\(pid)")
        signalGroup(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(pid, 0) == 0 {
            AppLog.write("pdf: worker pid=\(pid) did not stop; SIGKILL")
            signalGroup(pid, SIGKILL)
        }
    }

    /// Last-resort synchronous stop for `applicationWillTerminate`.
    func terminateSynchronously() {
        guard let pid, process?.isRunning == true else { return }
        signalGroup(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }
            usleep(50_000)
        }
        if kill(pid, 0) == 0 { signalGroup(pid, SIGKILL) }
        AppLog.write("pdf: worker stopped (sync) pid=\(pid)")
    }

    private func signalGroup(_ pid: pid_t, _ signal: Int32) {
        // The Python side calls setpgrp, so the group id is the child's pid.
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private func deliver(_ lines: [String]) {
        for line in lines {
            guard let event = PDFWorkerLine.parse(line) else { continue }
            onEvent?(event)
        }
    }

    private func exited(status: Int32) {
        process = nil
        AppLog.write("pdf: worker exited status=\(status)")
        onExit?(status)
    }
}

/// Joins the two things that end a worker: its pipe closing and its exit.
/// Whichever comes second reports the exit, exactly once.
private final class ExitJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var endOfFile = false
    private var status: Int32?
    private var reported = false

    /// Called at end of file. Returns the status when the process has already
    /// exited, so the caller reports it now.
    func reachedEndOfFile() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        endOfFile = true
        guard let status, !reported else { return nil }
        reported = true
        return status
    }

    /// Called at exit. True when end of file was already seen, so the caller
    /// reports the exit now; false means the end of file will report it.
    func exited(status: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        guard endOfFile, !reported else { return false }
        reported = true
        return true
    }

    /// Called after the grace period. True when nothing has reported yet.
    func forceExit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reported else { return false }
        reported = true
        return true
    }
}
