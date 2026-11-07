import Foundation
import Observation
import YakuCore

/// Installs the PDF worker's Python environment with `uv` (SPEC 8.2).
///
/// The environment goes into `~/Library/Application Support/Yaku/pdf-worker`,
/// Python 3.12, with `pdf2zh-next==2.9.0` and `bitstring<5`. Progress is
/// reported from `uv`'s own output so the first PDF can show what is happening
/// while several hundred megabytes are fetched.
@MainActor
@Observable
final class PDFWorkerInstaller {
    /// The size shown in the wording before anything is installed (SPEC 13:
    /// 「約 ___MB」). Measured during the M3 check and recorded in M3.md.
    /// Measured on this Mac: a fresh 3.12 environment with
    /// `pdf2zh-next==2.9.0` and `bitstring<5` is 957 MB on disk (22,987 files),
    /// and the install took 33 seconds (SPEC 13: 「約 ___MB」).
    static let estimatedSizeText = "950MB"

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

    private var process: Process?
    private var cancelled = false

    /// Runs `uv venv` and then `uv pip install -r requirements.txt`.
    func install() async {
        cancelled = false
        phase = .running
        progress = 0
        message = "Python 3.12 の環境を作っています…"
        AppLog.write("pdf-worker: install started")

        guard PDFWorkerPaths.uvIsAvailable else {
            fail("uv が見つかりません（\(PDFWorkerPaths.uvPath)）")
            return
        }
        guard let requirements = PDFWorkerPaths.requirementsFile else {
            fail("PDF ワーカーのファイルが見つかりません")
            return
        }

        let environment = PDFWorkerPaths.environmentDirectory
        try? FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)

        let uv = URL(fileURLWithPath: PDFWorkerPaths.uvPath)
        let venvStatus = await run(uv, [
            "venv", "--python", "3.12", "--allow-existing", environment.path,
        ])
        guard !cancelled else { return }
        guard venvStatus == 0 else {
            fail("Python 3.12 の環境を作れませんでした")
            return
        }

        progress = 0.2
        message = "部品を取得しています…"
        let installStatus = await run(uv, [
            "pip", "install",
            "--python", PDFWorkerPaths.installedPython.path,
            "-r", requirements.path,
        ])
        guard !cancelled else { return }
        guard installStatus == 0 else {
            fail("部品を取得できませんでした")
            return
        }

        progress = 0.97
        message = "大きさを測っています…"
        installedBytes = PDFWorkerPaths.installedBytes
        progress = 1
        message = "導入しました（\(ByteCount.format(installedBytes))）"
        phase = .done
        AppLog.write("pdf-worker: installed \(installedBytes) bytes at \(environment.path)")
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

        do {
            try process.run()
        } catch {
            self.process = nil
            fail("uv を起動できませんでした: \(error.localizedDescription)")
            return -1
        }

        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
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
        } else if line.contains("Installed") {
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
