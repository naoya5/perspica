import Foundation
import Observation
import YakuCore

/// The state the model cards show (SPEC 4.4).
@MainActor
@Observable
final class ModelDownloadState {
    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case finished
        case cancelled
        case failed(String)
    }

    var phase: Phase = .idle
    var modelID: String?
    var received: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0

    var isActive: Bool {
        switch phase {
        case .downloading, .verifying: true
        default: false
        }
    }

    var progress: Double {
        total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0
    }

    var progressText: String {
        "\(ByteCount.format(received)) / \(ByteCount.format(total))"
    }

    var speedText: String {
        guard phase == .downloading, bytesPerSecond > 0 else { return "" }
        return "\(ByteCount.format(Int64(bytesPerSecond)))/秒"
    }

    func reset() {
        phase = .idle
        modelID = nil
        received = 0
        total = 0
        bytesPerSecond = 0
    }
}

/// Append-only file writer used from the session's delegate queue.
///
/// The queue is serial, so writes arrive in order; the lock only guards the
/// main actor reading `count` for the progress line.
private final class FileSink: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var written: Int64

    init(url: URL, existingBytes: Int64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(max(0, existingBytes)))
        try handle.seekToEnd()
        written = max(0, existingBytes)
    }

    var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            AppLog.write("download: write failed \(error)")
        }
    }

    /// The server ignored our `Range` header and is sending the whole file.
    func restart() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        written = 0
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

/// Downloads a model from Hugging Face with a resumable partial file
/// (SPEC 7.5).
///
/// The transfer is a plain data task rather than a download task so the bytes
/// can be appended to a `.partial` file of our own: that file survives a
/// cancelled download *and* a restart of the app, which `URLSession`'s resume
/// data does not. Only huggingface.co is contacted.
@MainActor
final class ModelDownloader: NSObject {
    let state = ModelDownloadState()
    var onFinished: ((TranslationModel) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var current: TranslationModel?

    nonisolated(unsafe) private var sink: FileSink?
    nonisolated(unsafe) private var progressClock = Date()
    nonisolated(unsafe) private var progressBytes: Int64 = 0

    /// Why the response was refused, set on the delegate queue before the task
    /// is cancelled. The delegate queue is serial, so `didCompleteWithError`
    /// reads it after `didReceive response` wrote it, and the cancellation
    /// that follows a refused response is not shown as 「取り消しました」.
    private enum Refusal {
        case httpStatus(Int)
        /// 416: the partial file is longer than the server's file. It is
        /// deleted and the download starts again from zero, once.
        case staleRange
    }

    nonisolated(unsafe) private var refusal: Refusal?
    private var restartedAfterStaleRange = false

    override init() {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dev.naoya.yaku.model-download"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(_ model: TranslationModel) {
        guard !state.isActive else { return }
        restartedAfterStaleRange = false
        begin(model)
    }

    private func begin(_ model: TranslationModel) {
        current = model
        state.modelID = model.id
        state.total = model.bytes
        state.bytesPerSecond = 0
        state.phase = .downloading

        let partial = ModelStore.partialURL(for: model)
        var existing = ModelStore.partialBytes(model)
        if existing >= model.bytes {
            try? FileManager.default.removeItem(at: partial)
            existing = 0
        }
        do {
            sink = try FileSink(url: partial, existingBytes: existing)
        } catch {
            state.phase = .failed("保存先を用意できませんでした")
            AppLog.write("download: could not open \(partial.path) (\(error))")
            return
        }
        state.received = existing
        progressClock = Date()
        progressBytes = existing
        refusal = nil

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        AppLog.write("download start \(model.fileName) from=\(existing) url=\(model.downloadURL.absoluteString)")
        let task = (session ?? URLSession.shared).dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Stops the transfer and keeps the partial file so it can be resumed.
    func cancel() {
        guard let task else { return }
        AppLog.write("download cancel at \(sink?.count ?? 0) bytes")
        task.cancel()
        self.task = nil
    }

    func reset() {
        state.reset()
    }

    private func fail(_ message: String) {
        state.phase = .failed(message)
        AppLog.write("download failed: \(message)")
    }

    /// The server answered 416 to our `Range`: the `.partial` is longer than
    /// the file it has (a changed file, or a partial from another model). It
    /// is thrown away and the download restarts from zero, once; a second 416
    /// is reported like any other refused response.
    private func restartAfterStaleRange() {
        guard let model = current else { return }
        let partial = ModelStore.partialURL(for: model)
        try? FileManager.default.removeItem(at: partial)
        guard !restartedAfterStaleRange else {
            fail("サーバーが 416 を返しました")
            return
        }
        restartedAfterStaleRange = true
        AppLog.write("download: server answered 416; partial removed, starting again from 0")
        begin(model)
    }

    private func verify(written: Int64) async {
        guard let model = current else { return }
        state.phase = .verifying
        state.received = written
        let partial = ModelStore.partialURL(for: model)
        let expected = model.sha256
        AppLog.write("download finished \(written) bytes; checking SHA-256")

        let digest = await Task.detached(priority: .utility) {
            try? FileHash.sha256(ofFileAt: partial)
        }.value

        guard let digest else {
            fail("取得したファイルを読めませんでした")
            return
        }
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            AppLog.write("download hash mismatch got=\(digest) want=\(expected)")
            try? FileManager.default.removeItem(at: partial)
            fail("取得したファイルの SHA-256 が合いません")
            return
        }

        do {
            let destination = ModelStore.installedURL(for: model)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            AppLog.write("download: could not move into place (\(error))")
            fail("ファイルを置けませんでした")
            return
        }

        state.received = model.bytes
        state.phase = .finished
        AppLog.write("download verified \(model.fileName) sha256=\(digest)")
        onFinished?(model)
    }
}

extension ModelDownloader: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            // Either a fresh download, or the server ignored the Range header.
            sink?.restart()
        case 206:
            break
        case 416:
            refusal = .staleRange
            completionHandler(.cancel)
            return
        default:
            refusal = .httpStatus(status)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        sink?.append(data)
        let written = sink?.count ?? 0
        let now = Date()
        guard now.timeIntervalSince(progressClock) >= 0.25 else { return }
        let elapsed = now.timeIntervalSince(progressClock)
        let speed = Double(written - progressBytes) / max(elapsed, 0.001)
        progressClock = now
        progressBytes = written
        Task { @MainActor in
            self.state.received = written
            self.state.bytesPerSecond = speed
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let written = sink?.count ?? 0
        sink?.close()
        sink = nil
        let refusal = self.refusal
        self.refusal = nil

        Task { @MainActor in
            self.task = nil
            switch refusal {
            case .httpStatus(let status):
                self.fail("サーバーが \(status) を返しました")
                return
            case .staleRange:
                self.restartAfterStaleRange()
                return
            case nil:
                break
            }
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    self.state.phase = .cancelled
                    self.state.received = written
                    AppLog.write("download cancelled at \(written) bytes")
                } else {
                    self.fail("取得できませんでした: \(error.localizedDescription)")
                }
                return
            }
            await self.verify(written: written)
        }
    }
}
