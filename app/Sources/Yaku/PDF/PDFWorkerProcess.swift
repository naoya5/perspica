import Darwin
import Foundation
import YakuCore

/// Runs `translate_pdf.py` and turns its stdout into events (SPEC 8.2).
///
/// The worker is put into its own process group by the Python side, so a cancel
/// can signal the whole group: the per-paragraph translator processes that
/// pdf2zh-next starts die with it instead of being left behind.
@MainActor
final class PDFWorkerProcess {
    private var process: Process?
    private(set) var pid: pid_t?
    private nonisolated let splitter = LineSplitter()

    var onEvent: ((PDFWorkerEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func start(executable: URL, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        FileManager.default.createFile(atPath: AppPaths.pdfLog.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: AppPaths.pdfLog) {
            _ = try? log.seekToEnd()
            process.standardError = log
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            let lines = self.splitter.feed(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in self.deliver(lines) }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(status: status) }
        }

        try process.run()
        self.process = process
        self.pid = process.processIdentifier
        AppLog.write("pdf: worker started pid=\(process.processIdentifier) args=\(arguments.dropFirst().joined(separator: " "))")
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
