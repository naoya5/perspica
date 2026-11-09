import Foundation
import Observation
import YakuCore

/// Installs the PDF worker's Python environment with `uv` (SPEC 8.2).
///
/// The environment goes into `~/Library/Application Support/Yaku/pdf-worker`,
/// Python 3.12, synced to the hashed lock file `requirements.txt` so every
/// install is the same set of packages. The same run brings an existing
/// environment up to date when the requirements change. Progress is reported
/// from `uv`'s own output so the first PDF can show what is happening while
/// several hundred megabytes are fetched.
@MainActor
@Observable
final class PDFWorkerInstaller {
    /// The size shown in the wording before anything is installed (SPEC 13:
    /// 「約 ___MB」). Measured 2026-11-10: a 3.12 environment synced to the
    /// current requirements.txt (pdf2zh-next 2.10.2, BabelDOC 0.7.1) is
    /// 924 MB on disk.
    static let estimatedSizeText = "920MB"
    /// The same figure in bytes, for the demo's 導入済み size.
    static let estimatedBytes: Int64 = 924 * 1000 * 1000

    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)

        var isActive: Bool { self == .running }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var message = ""
    private(set) var installedBytes: Int64 = 0

    /// Called after a successful install, so the files that were waiting for
    /// the worker can run whichever surface started the install.
    var onInstalled: (() -> Void)?

    private var process: Process?
    private var cancelled = false

    /// Runs `uv venv` and then `uv pip sync` against the hashed lock file. A
    /// second call while one is running returns at once: the first run is
    /// the one the caller will see finish.
    func install() async {
        guard phase != .running else {
            AppLog.write("pdf-worker: install already running")
            return
        }
        let isUpdate = PDFWorkerPaths.isInstalled
        cancelled = false
        phase = .running
        progress = 0
        message = isUpdate ? "部品を確かめています…" : "Python 3.12 の環境を作っています…"
        AppLog.write(isUpdate ? "pdf-worker: sync started" : "pdf-worker: install started")

        guard let uvPath = PDFWorkerPaths.uvPath else {
            fail("uv が見つかりません（\(ExecutableLocator.searchDirectories.joined(separator: "、")) を探しました）。`brew install uv` で入れてください")
            return
        }
        guard let requirements = PDFWorkerPaths.requirementsFile else {
            fail("PDF ワーカーのファイルが見つかりません")
            return
        }

        let environment = PDFWorkerPaths.environmentDirectory
        try? FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)

        let uv = URL(fileURLWithPath: uvPath)
        let venvStatus = await run(uv, [
            "venv", "--python", "3.12", "--allow-existing", environment.path,
        ])
        guard !cancelled else { return }
        guard venvStatus == 0 else {
            fail("Python 3.12 の環境を作れませんでした")
            return
        }

        progress = 0.2
        message = isUpdate ? "部品を更新しています…" : "部品を取得しています…"
        // `sync` makes the environment exactly the lock file: packages that
        // left the file are removed, and every download is checked against
        // the hashes recorded in it.
        let installStatus = await run(uv, [
            "pip", "sync", "--require-hashes",
            "--python", PDFWorkerPaths.installedPython.path,
            requirements.path,
        ])
        guard !cancelled else { return }
        guard installStatus == 0 else {
            fail("部品を取得できませんでした")
            return
        }
        PDFWorkerPaths.writeRequirementsStamp()

        progress = 0.97
        message = "大きさを測っています…"
        installedBytes = PDFWorkerPaths.installedBytes
        progress = 1
        message = "導入しました（\(ByteCount.format(installedBytes))）"
        phase = .done
        AppLog.write("pdf-worker: installed \(installedBytes) bytes at \(environment.path)")
        onInstalled?()
    }

    func cancel() {
        cancelled = true
        process?.terminate()
        AppLog.write("pdf-worker: install cancelled")
        phase = .idle
        progress = 0
        message = ""
    }

    private func fail(_ text: String) {
        phase = .failed(text)
        message = text
        AppLog.write("pdf-worker: install failed: \(text)")
    }

    // MARK: running uv

    private func run(_ executable: URL, _ arguments: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process

        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in splitter.feed(data) {
                Task { @MainActor in self.consume(line) }
            }
        }

        // The handler is set before `run()`, so a child that exits at once
        // still resumes the continuation; a `run()` that throws resumes it
        // from the catch, and the handler never fires for a process that did
        // not start.
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                Task { @MainActor in
                    self.fail("uv を起動できませんでした: \(error.localizedDescription)")
                }
                continuation.resume(returning: -1)
            }
        }
        self.process = nil
        return status
    }

    /// Maps `uv`'s summary lines onto the progress bar; everything else is kept
    /// in the log so a failure can be read from `pdf.log`.
    private func consume(_ rawLine: String) {
        let line = stripANSI(rawLine)
        guard !line.isEmpty else { return }
        AppLog.write("pdf-worker uv: \(line)")
        if line.contains("Resolved") {
            progress = max(progress, 0.35)
        } else if line.contains("Prepared") {
            progress = max(progress, 0.6)
        } else if line.contains("Installed") || line.contains("Uninstalled") {
            progress = max(progress, 0.9)
        } else if line.contains("Downloading") || line.contains("Downloaded") {
            progress = max(progress, 0.45)
        }
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}
