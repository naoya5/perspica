import Darwin
import Foundation
import YakuCore

/// Owns the llama-server child process: starting it through the watchdog shell,
/// waiting for `/health`, stopping it after an idle period, and cleaning up a
/// leftover engine from a previous run that was killed before it could shut
/// down.
@MainActor
final class EngineManager {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Why the last start attempt failed, so the caller can pick the right
    /// message (SPEC 13: a missing model is not the same as a broken engine).
    enum StartFailure: Equatable {
        case executableMissing
        case modelMissing
        case portUnavailable
        case launchFailed
        case diedAtStartup
        case timedOut
    }

    /// Default: stop the engine ten minutes after the last request (SPEC 7.1).
    static let defaultIdleSeconds: Double = 600
    static let modelAlias = "plamo-3-translate"
    static let modelName = "plamo-3-translate"
    static let startupTimeout: TimeInterval = 15

    private(set) var state: State = .stopped
    private(set) var port: UInt16?
    private(set) var apiKey: String?
    private(set) var idleSeconds: Double = EngineManager.defaultIdleSeconds
    private(set) var lastStartFailure: StartFailure?

    /// The file the running engine is using, for the manager's status line.
    private(set) var loadedModelLabel: String?

    /// Set when the child process disappears without us asking it to (SPEC
    /// 7.1). The coordinator uses it to restart the engine once per request.
    private(set) var crashedUnexpectedly = false

    var onStateChange: ((State) -> Void)?

    /// The watchdog shell.
    private var process: Process?
    /// The llama-server the watchdog started.
    private var serverPid: pid_t?
    private var idleTimer: Timer?
    private var startTask: Task<Bool, Never>?
    /// True between "we are stopping it" and the process actually going away,
    /// so the termination handler does not mistake a normal stop for a crash.
    private var stoppingIntentionally = false
    /// Number of PDF jobs in flight. While one is running the idle countdown is
    /// suspended, so the engine is never stopped mid-document (SPEC 7.1).
    private var pdfWorkCount = 0

    var client: EngineClient? {
        guard let port, let apiKey else { return nil }
        return EngineClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: apiKey)
    }

    var isRunning: Bool { process?.isRunning == true && state == .running }

    func configure(idleSeconds: Double) {
        self.idleSeconds = max(0, idleSeconds)
        AppLog.write("engine idle seconds = \(self.idleSeconds)")
    }

    // MARK: lifecycle

    /// Starts the engine if it is not running. Concurrent calls share one start.
    @discardableResult
    func ensureRunning() async -> Bool {
        if isRunning {
            markUsed()
            return true
        }
        if let startTask { return await startTask.value }

        let task = Task { await self.performStart() }
        startTask = task
        let result = await task.value
        startTask = nil
        return result
    }

    /// Records that the engine was just used, restarting the idle countdown.
    func markUsed() {
        guard state == .running else { return }
        scheduleIdleStop()
    }

    /// A PDF job has started: keep the engine up whatever the idle setting says
    /// (SPEC 7.1: PDF の処理中は止めない).
    func beginPDFWork() {
        pdfWorkCount += 1
        idleTimer?.invalidate()
        idleTimer = nil
        AppLog.write("engine: PDF work started (count=\(pdfWorkCount)); idle stop suspended")
    }

    func endPDFWork() {
        pdfWorkCount = max(0, pdfWorkCount - 1)
        guard pdfWorkCount == 0 else { return }
        AppLog.write("engine: PDF work finished; idle stop resumed")
        scheduleIdleStop()
    }

    /// Starts the engine in the background without waiting (SPEC 7.1: the
    /// hotkeys begin loading the model right away).
    func warmUp() {
        guard !isRunning else { return }
        Task { [weak self] in _ = await self?.ensureRunning() }
    }

    /// Clears the crash flag once the caller has decided to restart.
    func acknowledgeCrash() {
        crashedUnexpectedly = false
    }

    func stop() async {
        idleTimer?.invalidate()
        idleTimer = nil
        stoppingIntentionally = true
        await stopProcess()
        stoppingIntentionally = false
        setState(.stopped)
    }

    /// Used when the model changes (SPEC 4.4: 使うモデルを変えたらエンジンを
    /// 起動し直す).
    @discardableResult
    func restart() async -> Bool {
        AppLog.write("engine: restarting for a model change")
        await stop()
        return await ensureRunning()
    }

    /// Best-effort synchronous stop for `applicationWillTerminate`.
    func stopSynchronously() {
        idleTimer?.invalidate()
        idleTimer = nil
        stoppingIntentionally = true

        let shell = process
        let server = serverPid ?? EngineWatchdog.serverPid()

        shell?.terminate()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let shellAlive = shell?.isRunning == true
            let serverAlive = server.map { kill($0, 0) == 0 } ?? false
            if !shellAlive && !serverAlive { break }
            usleep(50_000)
        }

        if let server, kill(server, 0) == 0 {
            kill(server, SIGKILL)
            AppLog.write("engine force killed server pid=\(server)")
        }
        if let shell, shell.isRunning, let pid = shell.processIdentifier as pid_t? {
            kill(pid, SIGKILL)
        }
        AppLog.write("engine stop (sync) shell=\(shell?.processIdentifier ?? 0) server=\(server ?? 0)")
        process = nil
        serverPid = nil
        EnginePidFile.remove()
        EngineWatchdog.clearPidFile()
    }

    private func performStart() async -> Bool {
        if isRunning { markUsed(); return true }
        setState(.starting)
        lastStartFailure = nil
        crashedUnexpectedly = false

        await reapLeftoverEngine()

        guard let executable = Self.locateExecutable() else {
            lastStartFailure = .executableMissing
            setState(.failed("llama-server が見つかりません"))
            AppLog.write("engine start failed: llama-server not found")
            return false
        }
        guard let resolution = ModelStore.resolve() else {
            lastStartFailure = .modelMissing
            setState(.failed("翻訳モデルが見つかりません"))
            AppLog.write("engine start failed: no model file")
            return false
        }
        let model = resolution.path
        guard let freePort = Self.freePort() else {
            lastStartFailure = .portUnavailable
            setState(.failed("空きポートを取得できませんでした"))
            AppLog.write("engine start failed: no free port")
            return false
        }
        let key = Self.randomAPIKey()

        guard let script = EngineWatchdog.install() else {
            lastStartFailure = .launchFailed
            setState(.failed("見張り役のスクリプトを用意できませんでした"))
            AppLog.write("engine start failed: watchdog script")
            return false
        }
        EngineWatchdog.clearPidFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The watchdog watches this process, so it needs the app's own pid.
        process.arguments = [
            script,
            "\(getpid())",
            AppPaths.watchdogPidFile.path,
            executable,
            "-m", model,
            "-c", "16384",
            "--parallel", "4",
            // Metal and flash attention (SPEC 3: the engine runs on Metal). The
            // weight repack that runs at load is what the warmup pass also
            // touches, so it is skipped: the first real request warms the graph
            // instead (measured first-token latency is unchanged, 0.034–0.046s).
            "-ngl", "99",
            "-fa", "on",
            "--no-warmup",
            "--host", "127.0.0.1",
            "--port", "\(freePort)",
            "--api-key", key,
            "--alias", Self.modelAlias,
            "--no-webui",
            "--log-disable",
        ]

        // The watchdog's lifeline (see EngineWatchdog): the Process keeps the
        // pipe's write end open for as long as it is held, and the kernel
        // closes it when this app exits.
        process.standardInput = Pipe()

        FileManager.default.createFile(atPath: AppPaths.engineLog.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: AppPaths.engineLog) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            lastStartFailure = .launchFailed
            setState(.failed("エンジンを起動できませんでした: \(error.localizedDescription)"))
            AppLog.write("engine start failed: \(error)")
            return false
        }

        // A crash (as opposed to a stop we asked for) is noticed here.
        let shellPid = process.processIdentifier
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.childExited(pid: shellPid, status: status)
            }
        }

        self.process = process
        self.port = freePort
        self.apiKey = key
        self.loadedModelLabel = resolution.label
        AppLog.write("engine start shell=\(shellPid) port=\(freePort) model=\(model) (\(resolution.label))")

        let serverPid = await waitForServerPid()
        self.serverPid = serverPid
        EnginePidFile.write(EnginePidRecord(
            pid: shellPid,
            serverPid: serverPid,
            port: freePort,
            apiKey: key,
            executable: executable,
            model: model,
            startedAt: ISO8601DateFormatter().string(from: Date())
        ))
        AppLog.write("engine start server=\(serverPid ?? 0) watchdog=\(EngineWatchdog.script.count) bytes")

        let client = EngineClient(baseURL: URL(string: "http://127.0.0.1:\(freePort)")!, apiKey: key)
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            if await client.health() {
                setState(.running)
                AppLog.write("engine ready server=\(serverPid ?? 0) in \(String(format: "%.2f", Self.startupTimeout - deadline.timeIntervalSinceNow))s")
                scheduleIdleStop()
                return true
            }
            if !process.isRunning {
                lastStartFailure = .diedAtStartup
                setState(.failed("エンジンが起動直後に終了しました"))
                AppLog.write("engine died during startup shell=\(shellPid)")
                self.process = nil
                self.serverPid = nil
                self.port = nil
                self.apiKey = nil
                EnginePidFile.remove()
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        lastStartFailure = .timedOut
        setState(.failed("エンジンの起動が \(Int(Self.startupTimeout)) 秒で終わりませんでした"))
        AppLog.write("engine startup timed out shell=\(shellPid)")
        stoppingIntentionally = true
        await stopProcess()
        stoppingIntentionally = false
        return false
    }

    private func waitForServerPid() async -> pid_t? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let pid = EngineWatchdog.serverPid(), pid > 0 { return pid }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// Called from the child's termination handler. If we did not ask for the
    /// exit, this was a crash and the next request may restart it once.
    private func childExited(pid: Int32, status: Int32) {
        guard let process, process.processIdentifier == pid else { return }
        let orphan = serverPid
        self.process = nil
        self.serverPid = nil
        self.port = nil
        self.apiKey = nil
        EngineWatchdog.clearPidFile()

        if stoppingIntentionally {
            EnginePidFile.remove()
            AppLog.write("engine exited shell=\(pid) status=\(status) (requested)")
            return
        }

        // The shell can go away on its own (for example if it is killed), and
        // the server it started would then be left with nothing watching it.
        // Stop it here, and keep the record when it survives so the next launch
        // can still find it.
        if let orphan, kill(orphan, 0) == 0 {
            AppLog.write("engine shell died; server pid=\(orphan) is still up; stopping it")
            kill(orphan, SIGTERM)
        } else {
            EnginePidFile.remove()
        }
        crashedUnexpectedly = true
        setState(.failed("エンジンが予期せず終了しました (status=\(status))"))
        AppLog.write("engine exited unexpectedly shell=\(pid) status=\(status)")
    }

    /// Stops the watchdog shell and the server it started.
    ///
    /// Asking the shell to terminate is enough in the normal case: its trap
    /// stops the server. The server is killed directly as well, so a shell that
    /// is already gone cannot leave llama-server behind.
    private func stopProcess() async {
        let shell = process
        let server = serverPid ?? EngineWatchdog.serverPid()

        if let shell, shell.isRunning {
            shell.terminate()
        }

        for _ in 0..<30 {
            let shellAlive = shell?.isRunning == true
            let serverAlive = server.map { kill($0, 0) == 0 } ?? false
            if !shellAlive && !serverAlive { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if let server, kill(server, 0) == 0 {
            kill(server, SIGTERM)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if kill(server, 0) == 0 {
                kill(server, SIGKILL)
                AppLog.write("engine force killed server pid=\(server)")
            }
        }
        if let shell, shell.isRunning, let pid = shell.processIdentifier as pid_t? {
            kill(pid, SIGKILL)
            AppLog.write("engine force killed watchdog pid=\(pid)")
        }

        AppLog.write("engine stop shell=\(shell?.processIdentifier ?? 0) server=\(server ?? 0)")
        process = nil
        serverPid = nil
        port = nil
        apiKey = nil
        EnginePidFile.remove()
        EngineWatchdog.clearPidFile()
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: idle stop

    private func scheduleIdleStop() {
        idleTimer?.invalidate()
        guard idleSeconds > 0 else {
            idleTimer = nil
            return
        }
        // A PDF in flight holds the engine open (SPEC 7.1).
        guard pdfWorkCount == 0 else {
            idleTimer = nil
            return
        }
        let timer = Timer(timeInterval: idleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AppLog.write("engine idle for \(Int(self.idleSeconds))s; stopping")
                Task { await self.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    // MARK: leftover engine from a previous run

    /// Stops an engine this app started in an earlier run that was force quit.
    /// Only a process whose command line carries our own alias, API key and
    /// port is touched; anything else (for example the shared engine on port
    /// 5191) is left alone.
    private func reapLeftoverEngine() async {
        guard let record = EnginePidFile.read() else { return }
        EnginePidFile.remove()

        var candidates: [pid_t] = []
        if let server = record.serverPid { candidates.append(server) }
        candidates.append(record.pid)

        var stoppedAny = false
        for pid in candidates where pid > 0 {
            guard kill(pid, 0) == 0 else {
                AppLog.write("leftover engine pid=\(pid) is gone")
                continue
            }
            guard let command = Self.commandLine(of: pid) else {
                AppLog.write("leftover engine pid=\(pid): could not read its command line; leaving it")
                continue
            }
            let matches = command.contains("llama-server")
                && command.contains("--api-key \(record.apiKey)")
                && command.contains("--port \(record.port)")
            guard matches else {
                AppLog.write("leftover engine pid=\(pid) is not ours; leaving it alone")
                continue
            }

            AppLog.write("stopping leftover engine pid=\(pid) port=\(record.port)")
            kill(pid, SIGTERM)
            var stopped = false
            for _ in 0..<30 {
                if kill(pid, 0) != 0 {
                    stopped = true
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !stopped {
                kill(pid, SIGKILL)
                AppLog.write("leftover engine pid=\(pid) force killed")
            } else {
                AppLog.write("leftover engine pid=\(pid) stopped")
            }
            stoppedAny = true
        }
        if stoppedAny { EngineWatchdog.clearPidFile() }
    }

    // MARK: environment

    static func locateExecutable() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/llama-server")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let homebrew = "/opt/homebrew/bin/llama-server"
        if FileManager.default.isExecutableFile(atPath: homebrew) {
            return homebrew
        }
        return nil
    }

    /// Opens a socket on port 0 and lets the OS pick a free port for us.
    static func freePort() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    static func randomAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func commandLine(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
