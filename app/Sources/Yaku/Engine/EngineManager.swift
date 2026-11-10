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
    /// SPEC 7.1: `GET /health` must answer 200 within 15 seconds of the
    /// launch, model load included; otherwise the start has failed.
    static let startupTimeout: TimeInterval = 15

    private(set) var state: State = .stopped
    private(set) var port: UInt16?
    private(set) var apiKey: String?
    private(set) var idleSeconds: Double = EngineManager.defaultIdleSeconds
    private(set) var lastStartFailure: StartFailure?

    /// The file the running engine is using, for the manager's status line.
    private(set) var loadedModelLabel: String?

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
    /// The current start saw `/health` answer 503 (model loading).
    private var startupSawLoading = false

    /// The four request slots every caller shares (SPEC 7.3).
    nonisolated let slots = EngineSlots(capacity: 4)
    /// The loopback proxy the PDF worker talks to, made on first use.
    private var pdfProxy: EngineProxy?
    /// Bumped every time the engine becomes ready, so a failed request can
    /// tell whether the engine it used is still the one serving.
    private(set) var generation: UInt64 = 0

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
        // `stop()` may have cancelled this start and `restart()` begun a new
        // one by the time this resumes; only clear our own task.
        if startTask == task { startTask = nil }
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

    // MARK: requests

    /// Streams one translation through the shared slots (SPEC 7.3).
    ///
    /// The request waits for a slot in priority order, starts the engine if
    /// needed and is fitted into one slot's 4,096 tokens. If the engine dies
    /// before the first piece, it is started once more and the request is sent
    /// again (SPEC 7.1). Once a piece has been yielded nothing is sent twice:
    /// a later failure ends the stream with `EngineStreamError.engineStopped`.
    /// Cancelling the consuming task releases the slot and closes the
    /// connection, which stops the generation.
    func stream(_ request: CompletionRequest, priority: EnginePriority) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: EngineStreamError.engineStopped)
                    return
                }
                do {
                    try await EngineRequestRunner.run(
                        priority: priority,
                        slots: self.slots,
                        ensureRunning: { [weak self] in await self?.ensureRunning() ?? false },
                        isServing: { [weak self] generation in await self?.isServing(generation) ?? false },
                        open: { [weak self] in
                            guard let self, let current = await self.currentClient() else {
                                throw EngineStreamError.engineStopped
                            }
                            let (client, generation) = current
                            let fitted = try await RequestBudget.fit(request) { try await client.tokenCount($0) }
                            await self.noteFitted(original: request, fitted: fitted, priority: priority)
                            return EngineAttempt(stream: client.stream(fitted), generation: generation)
                        },
                        onRestart: { [weak self] in await self?.noteRestart(priority) },
                        yield: { _ = continuation.yield($0) }
                    )
                    self.markUsed()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func currentClient() -> (EngineClient, UInt64)? {
        guard isRunning, let client else { return nil }
        return (client, generation)
    }

    /// Whether the engine that served `generation` is still up, checked
    /// without waiting for the termination callback: when llama-server dies,
    /// the socket error reaches the request before the watchdog shell has
    /// exited and `childExited` has run.
    ///
    /// A dead engine is forgotten here, before the request retries: until
    /// `childExited` runs, `isRunning` still says yes and `ensureRunning()`
    /// would hand back the same dead port instead of starting a new engine.
    private func isServing(_ generation: UInt64) async -> Bool {
        guard generation == self.generation, isRunning, let client else { return false }
        let pid = serverPid
        let alive = await EngineLiveness.isAlive(
            pidAlive: { pid.map { kill($0, 0) == 0 } },
            probe: { await client.healthProbe(timeout: $0) }
        )
        if alive { return generation == self.generation }
        forgetDeadEngine(generation)
        return false
    }

    /// Drops the engine of `generation` so the next `ensureRunning()` starts a
    /// new one through the shared start. Its later `childExited` finds a
    /// different (or no) process and changes nothing.
    private func forgetDeadEngine(_ generation: UInt64) {
        guard generation == self.generation, state == .running, startTask == nil else { return }
        let shell = process
        let server = serverPid
        AppLog.write("engine: generation \(generation) stopped serving "
            + "shell=\(shell?.processIdentifier ?? 0) server=\(server ?? 0); forgetting it")
        process = nil
        serverPid = nil
        port = nil
        apiKey = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let server, server > 0, kill(server, 0) == 0 { kill(server, SIGKILL) }
        if let shell, shell.isRunning { shell.terminate() }
        EnginePidFile.remove()
        EngineWatchdog.clearPidFile()
        setState(.failed("エンジンが予期せず終了しました"))
    }

    private func noteFitted(original: CompletionRequest, fitted: CompletionRequest, priority: EnginePriority) {
        markUsed()
        guard fitted != original else { return }
        AppLog.write("engine: \(priority) request trimmed to fit 4096 tokens "
            + "(prompt \(original.prompt.utf8.count)→\(fitted.prompt.utf8.count) bytes, "
            + "max_tokens \(original.maxTokens)→\(fitted.maxTokens))")
    }

    private func noteRestart(_ priority: EnginePriority) {
        AppLog.write("engine: died before a \(priority) request answered; starting it once more")
    }

    /// The address and key the PDF worker uses (SPEC 7.3: PDF goes through
    /// the same slots, at the lowest priority). The proxy starts the engine
    /// per request, so this does not need the engine to be running.
    func ensurePDFEndpoint() async -> (url: URL, apiKey: String)? {
        if let pdfProxy, pdfProxy.port > 0 {
            return (URL(string: "http://127.0.0.1:\(pdfProxy.port)")!, pdfProxy.apiKey)
        }
        let proxy = EngineProxy(apiKey: Self.randomAPIKey()) { [weak self] request in
            guard let self else { return .error(status: 503, "engine unavailable") }
            return await Self.handleProxy(request, engine: self)
        }
        do {
            let port = try proxy.start()
            pdfProxy = proxy
            AppLog.write("engine: PDF proxy listening on 127.0.0.1:\(port)")
            return (URL(string: "http://127.0.0.1:\(port)")!, proxy.apiKey)
        } catch {
            AppLog.write("engine: PDF proxy could not start (\(error))")
            return nil
        }
    }

    nonisolated private static func handleProxy(_ request: ProxyRequest, engine: EngineManager) async -> ProxyReply {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            // The proxy starts the engine for each request, so it is ready
            // whenever it answers.
            return .json(status: 200, ["status": "ok"])
        case ("POST", "/v1/completions"):
            break
        case ("POST", "/tokenize"):
            return await proxyTokenize(request, engine: engine)
        case (_, "/health"), (_, "/v1/completions"), (_, "/tokenize"):
            return .error(status: 405, "method not allowed")
        default:
            return .error(status: 404, "not found")
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              object["prompt"] is String else {
            return .error(status: 400, "a string prompt is required")
        }
        let streaming = (object["stream"] as? Bool) ?? false
        let body = request.body
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    try await EngineRequestRunner.run(
                        priority: .pdf,
                        slots: engine.slots,
                        ensureRunning: { await engine.ensureRunning() },
                        isServing: { await engine.isServing($0) },
                        open: {
                            guard let current = await engine.currentClient() else {
                                throw EngineStreamError.engineStopped
                            }
                            let (client, generation) = current
                            let upstream = try await Self.fittedProxyBody(body, client: client)
                            await engine.markUsed()
                            return EngineAttempt(
                                stream: client.rawCompletion(body: upstream, expectsDone: streaming),
                                generation: generation
                            )
                        },
                        onRestart: { await engine.noteRestart(.pdf) },
                        yield: { _ = continuation.yield($0) }
                    )
                    await engine.markUsed()
                    continuation.finish()
                } catch EngineStreamError.requestTooLarge {
                    continuation.finish(throwing: ProxyHTTPError(status: 413, message: "the request does not fit in 4096 tokens"))
                } catch EngineStreamError.startFailed {
                    continuation.finish(throwing: ProxyHTTPError(status: 503, message: "the engine could not be started"))
                } catch EngineStreamError.engineStopped {
                    continuation.finish(throwing: ProxyHTTPError(status: 503, message: "the engine stopped"))
                } catch EngineError.httpStatus(let status) {
                    continuation.finish(throwing: ProxyHTTPError(status: status, message: "engine answered \(status)"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ProxyReply(
            status: 200,
            contentType: streaming ? "text/event-stream" : "application/json",
            body: stream
        )
    }

    /// Lets the worker count a prompt exactly as `/v1/completions` will. It
    /// takes no slot: tokenizing does not use one of the engine's sequences.
    nonisolated private static func proxyTokenize(_ request: ProxyRequest, engine: EngineManager) async -> ProxyReply {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let content = object["content"] as? String else {
            return .error(status: 400, "a string content is required")
        }
        guard await engine.ensureRunning(), let client = await engine.client else {
            return .error(status: 503, "the engine could not be started")
        }
        do {
            let tokens = try await client.tokenize(content)
            await engine.markUsed()
            return .json(status: 200, ["count": tokens.count, "tokens": tokens])
        } catch {
            return .error(status: 503, "the engine could not tokenize")
        }
    }

    /// The worker's body with `max_tokens` fitted into one slot and the
    /// engine's alias as the model. Everything else is sent as it came.
    nonisolated private static func fittedProxyBody(_ body: Data, client: EngineClient) async throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = object["prompt"] as? String else {
            throw ProxyHTTPError(status: 400, message: "a string prompt is required")
        }
        let asked = (object["max_tokens"] as? Int) ?? (object["n_predict"] as? Int) ?? CompletionRequest.maximumMaxTokens
        let requested = CompletionRequest(prompt: prompt, maxTokens: max(1, min(asked, CompletionRequest.maximumMaxTokens)))
        let fitted = try await RequestBudget.fit(requested) { try await client.tokenCount($0) }
        object["max_tokens"] = fitted.maxTokens
        object.removeValue(forKey: "n_predict")
        object["model"] = modelAlias
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The running llama-server's memory as Activity Monitor shows it
    /// (`phys_footprint`), for the settings' engine status.
    var residentMemoryBytes: UInt64? {
        guard isRunning, let serverPid, serverPid > 0 else { return nil }
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(serverPid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    func stop() async {
        idleTimer?.invalidate()
        idleTimer = nil
        // A start still in progress is cancelled and waited for first, so a
        // model change during a warm-up does not keep the old start (and the
        // old model) alive, and `restart()` begins from a clean state.
        if let startTask {
            AppLog.write("engine: stop while starting; cancelling the start")
            startTask.cancel()
            _ = await startTask.value
            self.startTask = nil
        }
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
        pdfProxy?.stop()
        pdfProxy = nil
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

        await reapLeftoverEngine()
        // Cancelled by `stop()`: it owns the state from here on.
        if Task.isCancelled { return false }

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
            "--alias", Self.modelAlias,
            "--no-webui",
            "--log-disable",
        ]
        // The key travels in the environment (llama-server reads
        // LLAMA_API_KEY), not in argv: every local account can read another
        // process's command line with `ps`. The watchdog is /bin/sh and hands
        // its environment to the server unchanged.
        var environment = ProcessInfo.processInfo.environment
        environment["LLAMA_API_KEY"] = key
        process.environment = environment

        // The watchdog's lifeline (see EngineWatchdog): the Process keeps the
        // pipe's write end open for as long as it is held, and the kernel
        // closes it when this app exits.
        process.standardInput = Pipe()

        // SPEC 11: engine.log rotates at 5 MB while the engine runs too, so
        // the app writes it rather than the child.
        let log = AppLog.rotatingPipe(for: AppPaths.engineLog)
        process.standardOutput = log
        process.standardError = log

        // A crash (as opposed to a stop we asked for) is noticed here. The
        // handler is installed before `run()`, so a child that exits at once
        // cannot slip past it.
        process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.childExited(pid: pid, status: status)
            }
        }

        do {
            try process.run()
        } catch {
            lastStartFailure = .launchFailed
            setState(.failed("エンジンを起動できませんでした: \(error.localizedDescription)"))
            AppLog.write("engine start failed: \(error)")
            return false
        }

        let shellPid = process.processIdentifier
        let launched = Date()
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
            executable: executable,
            model: model,
            startedAt: ISO8601DateFormatter().string(from: Date())
        ))
        AppLog.write("engine start server=\(serverPid ?? 0) watchdog=\(EngineWatchdog.script.count) bytes")
        if Task.isCancelled { return false }

        let client = EngineClient(baseURL: URL(string: "http://127.0.0.1:\(freePort)")!, apiKey: key)
        let deadline = launched.addingTimeInterval(Self.startupTimeout)
        startupSawLoading = false
        let outcome = await EngineStartupWait.waitForReady(
            deadline: deadline,
            probe: { await client.healthStatus(timeout: $0) },
            isAlive: { [weak self] in await self?.isShellRunning(shellPid) ?? false },
            onLoading: { [weak self] in await self?.noteStartupLoading(since: launched) }
        )
        switch outcome {
        case .cancelled:
            return false
        case .ready:
            if Task.isCancelled { return false }
            generation += 1
            setState(.running)
            AppLog.write("engine ready server=\(serverPid ?? 0) in \(String(format: "%.2f", Date().timeIntervalSince(launched)))s")
            scheduleIdleStop()
            return true
        case .died:
            if Task.isCancelled { return false }
            lastStartFailure = .diedAtStartup
            setState(.failed("エンジンが起動直後に終了しました"))
            AppLog.write("engine died during startup shell=\(shellPid)")
            self.process = nil
            self.serverPid = nil
            self.port = nil
            self.apiKey = nil
            EnginePidFile.remove()
            return false
        case .timedOut:
            break
        }
        if Task.isCancelled { return false }

        let limit = Int(Self.startupTimeout)
        lastStartFailure = .timedOut
        setState(.failed("エンジンの起動が \(limit) 秒で終わりませんでした"))
        AppLog.write("engine startup timed out shell=\(shellPid) after \(limit)s (loading=\(startupSawLoading))")
        stoppingIntentionally = true
        await stopProcess()
        stoppingIntentionally = false
        return false
    }

    /// The watchdog shell of this start is still up (`childExited` clears
    /// `process` when it goes).
    private func isShellRunning(_ pid: Int32) -> Bool {
        guard let process, process.processIdentifier == pid else { return false }
        return process.isRunning
    }

    private func noteStartupLoading(since launched: Date) {
        startupSawLoading = true
        AppLog.write("engine loading the model (503) \(String(format: "%.2f", Date().timeIntervalSince(launched)))s after launch")
    }

    private func waitForServerPid() async -> pid_t? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !Task.isCancelled {
            if let pid = EngineWatchdog.serverPid(), pid > 0 { return pid }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// Called from the child's termination handler. If we did not ask for the
    /// exit, this was a crash; the request that notices it starts the engine
    /// once more (`EngineRequestRunner`).
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
    /// Only a process whose command line carries llama-server, our own port
    /// and our alias is touched (the key is not on the command line any more);
    /// anything else, for example a llama-server the user runs, is left alone.
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
                && command.contains("--port \(record.port)")
                && command.contains("--alias \(Self.modelAlias)")
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
        return ExecutableLocator.find("llama-server")
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
