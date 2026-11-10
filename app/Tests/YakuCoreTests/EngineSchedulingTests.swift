// The scheduler, the request budget and the PDF proxy, the last over real
// loopback sockets. Every helper here is portable, so the file also runs
// with a Linux toolchain against just these YakuCore sources.
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
private func rawSend(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Darwin.send(fd, p, n, 0) }
#else
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
private func rawSend(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Glibc.send(fd, p, n, Int32(MSG_NOSIGNAL)) }
#endif
@testable import YakuCore

private actor Log {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func bump() -> Int { lock.lock(); value += 1; let v = value; lock.unlock(); return v }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("EngineSlots")
struct SlotTests {
    @Test("free slots are granted at once, then the highest priority waiter wins")
    func priorityOrder() async throws {
        let slots = EngineSlots(capacity: 4)
        var held: [EngineSlots.Ticket] = []
        for _ in 0..<4 { held.append(try await slots.acquire(.pdf)) }
        #expect(await slots.inFlight == 4)
        let log = Log()
        let pdf = Task { let t = try await slots.acquire(.pdf); await log.add("pdf"); return t }
        try await Task.sleep(nanoseconds: 50_000_000)
        let screen = Task { let t = try await slots.acquire(.screen); await log.add("screen"); return t }
        try await Task.sleep(nanoseconds: 50_000_000)
        let interactive = Task { let t = try await slots.acquire(.interactive); await log.add("interactive"); return t }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await slots.waiting == 3)
        await slots.release(held.removeLast())
        let first = try await interactive.value
        await slots.release(held.removeLast())
        let second = try await screen.value
        await slots.release(held.removeLast())
        let third = try await pdf.value
        #expect(await log.items == ["interactive", "screen", "pdf"])
        for t in held + [first, second, third] { await slots.release(t) }
        #expect(await slots.inFlight == 0)
    }

    @Test("a new request does not jump ahead of an equal or higher priority waiter")
    func noBarging() async throws {
        let slots = EngineSlots(capacity: 1)
        let a = try await slots.acquire(.pdf)
        let waiter = Task { try await slots.acquire(.interactive) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await slots.release(a)
        let b = try await waiter.value
        #expect(b.priority == .interactive)
        await slots.release(b)
    }

    @Test("cancelling a waiter removes it and never leaks a slot")
    func cancelWaiter() async throws {
        let slots = EngineSlots(capacity: 1)
        let a = try await slots.acquire(.pdf)
        let waiter = Task { try await slots.acquire(.interactive) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        #expect(await slots.waiting == 0)
        await slots.release(a)
        #expect(await slots.inFlight == 0)
        // Many cancel races.
        for _ in 0..<200 {
            let hold = try await slots.acquire(.pdf)
            let t = Task { try await slots.acquire(.screen) }
            t.cancel()
            await slots.release(hold)
            if let ticket = try? await t.value { await slots.release(ticket) }
        }
        #expect(await slots.inFlight == 0)
        #expect(await slots.waiting == 0)
    }
}

private enum Boom: Error { case died, http }

/// Follows EngineManager's rules: `ensureRunning` trusts a cached flag that
/// the termination callback clears late, concurrent starts share one task,
/// and `isServing` checks liveness and forgets a dead engine of its own
/// generation.
private actor CachedEngine {
    private(set) var running = true
    private(set) var generation: UInt64 = 1
    private(set) var starts = 0
    private(set) var opens = 0
    private var serverAlive = true
    private var startTask: Task<Bool, Never>?
    private let invalidates: Bool

    init(invalidates: Bool = true) { self.invalidates = invalidates }

    /// The server dies; the cached flag still says running.
    func crash() { serverAlive = false }

    func ensureRunning() async -> Bool {
        if running { return true }
        if let startTask { return await startTask.value }
        let task = Task { await self.performStart() }
        startTask = task
        let result = await task.value
        if startTask == task { startTask = nil }
        return result
    }

    private func performStart() async -> Bool {
        try? await Task.sleep(nanoseconds: 20_000_000)
        starts += 1
        generation += 1
        serverAlive = true
        running = true
        return true
    }

    /// The server is up but too busy to answer `/health` in time.
    private(set) var busy = false
    private(set) var probes: [TimeInterval] = []
    func setBusy(_ value: Bool) { busy = value }

    private func probe(_ timeout: TimeInterval) -> EngineHealthProbe {
        probes.append(timeout)
        if busy { return .timedOut }
        return serverAlive ? .status(200) : .refused
    }

    func isServing(_ g: UInt64) async -> Bool {
        guard g == generation, running else { return false }
        let alive = await EngineLiveness.isAlive(
            pidAlive: { await self.serverAlive },
            probe: { await self.probe($0) }
        )
        if alive { return g == generation }
        if invalidates, g == generation, running, startTask == nil { running = false }
        return false
    }

    func open() throws -> (UInt64, Bool) {
        opens += 1
        guard running else { throw EngineStreamError.engineStopped }
        return (generation, serverAlive)
    }
}

@Suite("EngineRequestRunner")
struct RunnerTests {
    final class Engine: @unchecked Sendable {
        let lock = NSLock()
        var running = true
        var starts = 0
        var opens = 0
        var startResult = true
        func set(_ r: Bool) { lock.lock(); running = r; lock.unlock() }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func ensure() -> Bool { lock.lock(); defer { lock.unlock() }; if !running { starts += 1; running = startResult }; return running }
        func open() -> Int { lock.lock(); defer { lock.unlock() }; opens += 1; return opens }
    }

    static func stream(_ items: [String], thenDie engine: Engine?, error: Error? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            for i in items { c.yield(i) }
            if let engine { engine.set(false) }
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
    }

    @Test("dies before the first piece: started once more and sent again")
    func retryBeforeOutput() async throws {
        let engine = Engine()
        let slots = EngineSlots()
        let out = Log()
        try await EngineRequestRunner.run(
            priority: .interactive, slots: slots,
            ensureRunning: { engine.ensure() }, isServing: { _ in engine.isRunning },
            open: { EngineAttempt(stream: engine.open() == 1 ? Self.stream([], thenDie: engine, error: Boom.died) : Self.stream(["a", "b"], thenDie: nil), generation: 0) },
            yield: { await out.add($0) })
        #expect(await out.items == ["a", "b"])
        #expect(engine.starts == 1)
        #expect(engine.opens == 2)
        #expect(await slots.inFlight == 0)
    }

    @Test("dies after a piece: no resend, engineStopped, no duplicate text")
    func noRetryAfterOutput() async throws {
        let engine = Engine()
        let slots = EngineSlots()
        let out = Log()
        await #expect(throws: EngineStreamError.engineStopped) {
            try await EngineRequestRunner.run(
                priority: .screen, slots: slots,
                ensureRunning: { engine.ensure() }, isServing: { _ in engine.isRunning },
                open: { _ = engine.open(); return EngineAttempt(stream: Self.stream(["partial"], thenDie: engine, error: Boom.died), generation: 0) },
                yield: { await out.add($0) })
        }
        #expect(await out.items == ["partial"])
        #expect(engine.opens == 1)
        #expect(await slots.inFlight == 0)
    }

    @Test("a silent end while the engine is gone counts as a crash")
    func silentEnd() async throws {
        let engine = Engine()
        let slots = EngineSlots()
        let out = Log()
        await #expect(throws: EngineStreamError.engineStopped) {
            try await EngineRequestRunner.run(
                priority: .pdf, slots: slots,
                ensureRunning: { engine.ensure() }, isServing: { _ in engine.isRunning },
                open: { _ = engine.open(); return EngineAttempt(stream: Self.stream(["x"], thenDie: engine, error: Boom.died), generation: 0) },
                yield: { await out.add($0) })
        }
    }

    @Test("dies twice: one restart only, then engineStopped")
    func onlyOnce() async throws {
        let engine = Engine()
        let slots = EngineSlots()
        await #expect(throws: EngineStreamError.engineStopped) {
            try await EngineRequestRunner.run(
                priority: .interactive, slots: slots,
                ensureRunning: { engine.ensure() }, isServing: { _ in engine.isRunning },
                open: { _ = engine.open(); return EngineAttempt(stream: Self.stream([], thenDie: engine, error: Boom.died), generation: 0) },
                yield: { _ in })
        }
        #expect(engine.opens == 2)
        #expect(engine.starts == 1)
        #expect(await slots.inFlight == 0)
    }

    @Test("socket error before the exit is noticed: the dead engine is forgotten and started once")
    func staleStateStillRestarts() async throws {
        let engine = CachedEngine()
        await engine.crash()
        let out = Log()
        try await Self.runOn(engine, out: out)
        #expect(await out.items == ["ok"])
        #expect(await engine.starts == 1)
        #expect(await engine.opens == 2)
    }

    @Test("without forgetting the dead engine the cached flag blocks the restart")
    func cachedFlagNeedsInvalidation() async throws {
        let engine = CachedEngine(invalidates: false)
        await engine.crash()
        await #expect(throws: EngineStreamError.engineStopped) {
            try await Self.runOn(engine, out: Log())
        }
        #expect(await engine.starts == 0)
    }

    @Test("requests crash together: exactly one shared restart, each retried once")
    func parallelCrash() async throws {
        for _ in 0..<20 {
            let engine = CachedEngine()
            await engine.crash()
            let slots = EngineSlots()
            let outs = (0..<4).map { _ in Log() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for out in outs { group.addTask { try await Self.runOn(engine, out: out, slots: slots) } }
                try await group.waitForAll()
            }
            for out in outs { #expect(await out.items == ["ok"]) }
            #expect(await engine.starts == 1)
            #expect(await slots.inFlight == 0)
        }
    }

    @Test("a busy live engine whose health check times out is kept: no restart, other requests finish")
    func busyEngineNotForgotten() async throws {
        let engine = CachedEngine()
        await engine.setBusy(true)
        let slots = EngineSlots()
        let gate = Flag()
        let other = Log()
        // A long request already being served by the same engine.
        let long = Task {
            try await EngineRequestRunner.run(
                priority: .screen, slots: slots,
                ensureRunning: { await engine.ensureRunning() },
                isServing: { await engine.isServing($0) },
                open: {
                    let (generation, _) = try await engine.open()
                    return EngineAttempt(stream: AsyncThrowingStream<String, Error> { c in
                        Task {
                            c.yield("part")
                            while gate.count == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
                            c.yield("rest")
                            c.finish()
                        }
                    }, generation: generation)
                },
                yield: { await other.add($0) })
        }
        // A second request fails (for example a slow upstream) on the busy engine.
        await #expect(throws: Boom.http) {
            try await EngineRequestRunner.run(
                priority: .interactive, slots: slots,
                ensureRunning: { await engine.ensureRunning() },
                isServing: { await engine.isServing($0) },
                open: {
                    let (generation, _) = try await engine.open()
                    return EngineAttempt(stream: Self.stream([], thenDie: nil, error: Boom.http), generation: generation)
                },
                yield: { _ in })
        }
        #expect(await engine.probes == [EngineLiveness.firstProbeTimeout, EngineLiveness.secondProbeTimeout])
        #expect(await engine.running)
        #expect(await engine.starts == 0)
        gate.bump()
        try await long.value
        #expect(await other.items == ["part", "rest"])
        #expect(await slots.inFlight == 0)
    }

    @Test("liveness: only a gone process or a refused port is death")
    func livenessRules() async {
        func check(_ pid: Bool?, _ answers: [EngineHealthProbe]) async -> (Bool, Int) {
            let log = Log()
            let alive = await EngineLiveness.isAlive(pidAlive: { pid }, probe: { timeout in
                await log.add("\(timeout)")
                let n = await log.items.count
                return answers[min(n, answers.count) - 1]
            })
            return (alive, await log.items.count)
        }
        #expect(await check(false, [.status(200)]) == (false, 0))
        #expect(await check(true, [.status(200)]) == (true, 1))
        #expect(await check(true, [.status(503)]) == (true, 1))
        #expect(await check(true, [.refused]) == (false, 1))
        #expect(await check(nil, [.refused]) == (false, 1))
        #expect(await check(true, [.timedOut, .timedOut]) == (true, 2))
        #expect(await check(nil, [.timedOut, .timedOut]) == (true, 2))
        #expect(await check(true, [.timedOut, .refused]) == (false, 2))
        #expect(await check(true, [.timedOut, .status(200)]) == (true, 2))
    }

    @Test("a request rejected before it reaches the engine is not resent")
    func preAttemptErrorNotRetried() async throws {
        let opens = Flag()
        let restarts = Flag()
        await #expect(throws: ProxyHTTPError.self) {
            try await EngineRequestRunner.run(priority: .pdf, slots: EngineSlots(),
                ensureRunning: { true }, isServing: { _ in false },
                open: { () async throws -> EngineAttempt<String> in
                    opens.bump(); throw ProxyHTTPError(status: 400, message: "bad")
                },
                onRestart: { restarts.bump() }, yield: { _ in })
        }
        #expect(opens.count == 1)
        #expect(restarts.count == 0)
    }

    @Test("no engine to send to before the attempt counts as a crash and is retried once")
    func preAttemptNoEngineRetried() async throws {
        let opens = Flag()
        let out = Log()
        try await EngineRequestRunner.run(priority: .screen, slots: EngineSlots(),
            ensureRunning: { true }, isServing: { _ in false },
            open: {
                if opens.bump() == 1 { throw EngineStreamError.engineStopped }
                return EngineAttempt(stream: Self.stream(["ok"], thenDie: nil), generation: 1)
            },
            yield: { await out.add($0) })
        #expect(opens.count == 2)
        #expect(await out.items == ["ok"])
    }

    private static func runOn(_ engine: CachedEngine, out: Log, slots: EngineSlots = EngineSlots()) async throws {
        try await EngineRequestRunner.run(
            priority: .interactive, slots: slots,
            ensureRunning: { await engine.ensureRunning() },
            isServing: { await engine.isServing($0) },
            open: {
                let (generation, alive) = try await engine.open()
                let stream = alive ? Self.stream(["ok"], thenDie: nil) : Self.stream([], thenDie: nil, error: Boom.died)
                return EngineAttempt(stream: stream, generation: generation)
            },
            yield: { await out.add($0) })
    }

    @Test("too large is never retried")
    func tooLargeNoRetry() async throws {
        let opens = Flag()
        await #expect(throws: EngineStreamError.requestTooLarge) {
            try await EngineRequestRunner.run(priority: .pdf, slots: EngineSlots(),
                ensureRunning: { true }, isServing: { _ in false },
                open: { () async throws -> EngineAttempt<String> in opens.bump(); throw EngineStreamError.requestTooLarge }, yield: { _ in })
        }
        #expect(opens.count == 1)
    }

    @Test("start failure is startFailed; a request error with the engine up is passed on")
    func failures() async throws {
        let engine = Engine()
        engine.running = false
        engine.startResult = false
        let slots = EngineSlots()
        await #expect(throws: EngineStreamError.startFailed) {
            try await EngineRequestRunner.run(priority: .interactive, slots: slots,
                ensureRunning: { engine.ensure() }, isServing: { _ in engine.isRunning },
                open: { EngineAttempt(stream: Self.stream([], thenDie: nil), generation: 0) }, yield: { _ in })
        }
        let up = Engine()
        await #expect(throws: Boom.http) {
            try await EngineRequestRunner.run(priority: .interactive, slots: slots,
                ensureRunning: { up.ensure() }, isServing: { _ in up.isRunning },
                open: { EngineAttempt(stream: Self.stream([], thenDie: nil, error: Boom.http), generation: 0) }, yield: { _ in })
        }
        #expect(await slots.inFlight == 0)
    }
}

@Suite("RequestBudget")
struct BudgetTests {
    @Test("a short request is not counted")
    func short() async throws {
        let request = PFML3.request(source: "Hello", targetLanguage: "ja")
        let flag = Flag()
        let fitted = try await RequestBudget.fit(request) { _ in flag.bump(); return 0 }
        #expect(fitted == request)
        #expect(flag.count == 0)
        #expect(request.parts?.source == "Hello")
    }

    @Test("an over-budget request keeps its source and drops history, glossary, then context")
    func trims() async throws {
        let big = String(repeating: "あ", count: 400)
        let history = [HistoryPair(source: big, target: big), HistoryPair(source: big, target: big)]
        let glossary = (0..<20).map { GlossaryPair(source: "t\($0)", target: "u\($0)") }
        let request = PFML3.request(source: String(repeating: "い", count: 600), targetLanguage: "en",
                                    context: String(repeating: "c", count: 600), history: history, glossary: glossary)
        // A pretend tokenizer: one token per character.
        let fitted = try await RequestBudget.fit(request) { $0.count }
        #expect(fitted.prompt.count + fitted.maxTokens <= 4096)
        #expect(fitted.parts?.source == request.parts?.source)
        #expect(fitted.prompt.contains(String(repeating: "い", count: 600)))
        #expect(fitted.parts!.history.count < 2 || fitted.parts!.glossary.count < 20)
    }

    @Test("trimming a long glossary takes few exact counts")
    func fewCounts() async throws {
        let glossary = (0..<400).map { GlossaryPair(source: "term\($0)", target: "訳語\($0)") }
        let request = PFML3.request(source: String(repeating: "い", count: 600), targetLanguage: "en", glossary: glossary)
        let calls = Flag()
        let fitted = try await RequestBudget.fit(request) { calls.bump(); return $0.utf8.count / 2 }
        #expect(fitted.prompt.utf8.count / 2 + fitted.maxTokens <= 4096)
        #expect(calls.count <= 4)
        #expect(fitted.parts!.glossary.count > 0)
    }

    @Test("the exact count decides: a prompt that fits by count is untouched")
    func exactKeeps() async throws {
        let request = PFML3.request(source: String(repeating: "い", count: 1000), targetLanguage: "en",
                                    context: String(repeating: "c", count: 600))
        #expect(!RequestBudget.fitsWithoutCounting(request))
        let fitted = try await RequestBudget.fit(request) { _ in 1500 }
        #expect(fitted == request)
    }

    @Test("max_tokens is lowered, never below 256; otherwise too large")
    func lowers() async throws {
        let request = CompletionRequest(prompt: String(repeating: "x", count: 3000), maxTokens: 2048)
        let fitted = try await RequestBudget.fit(request) { _ in 3000 }
        #expect(fitted.maxTokens == 1096)
        await #expect(throws: EngineStreamError.requestTooLarge) {
            _ = try await RequestBudget.fit(request) { _ in 3900 }
        }
    }

    @Test("a tokenizer failure falls back to the byte upper bound")
    func fallback() async throws {
        let request = CompletionRequest(prompt: String(repeating: "x", count: 3000), maxTokens: 2048)
        let fitted = try await RequestBudget.fit(request) { _ in throw Boom.http }
        #expect(fitted.maxTokens == 4096 - 3001)
    }
}

// MARK: proxy over real sockets

private func connectTo(_ port: UInt16) -> Int32 {
    let fd = socket(AF_INET, streamSocket, 0)
    #if canImport(Darwin)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let r = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    precondition(r == 0)
    return fd
}

private func sendRaw(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { rawSend(fd, $0.baseAddress, $0.count) }
}

private func readAll(_ fd: Int32) -> String {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    close(fd)
    return String(decoding: out, as: UTF8.self)
}

private func request(_ port: UInt16, _ raw: String) async -> String {
    await Task.detached {
        let fd = connectTo(port)
        sendRaw(fd, raw)
        return readAll(fd)
    }.value
}

private func post(_ path: String, key: String?, body: String) -> String {
    var s = "POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
    if let key { s += "Authorization: Bearer \(key)\r\n" }
    return s + "\r\n" + body
}

@Suite("EngineProxy", .serialized)
struct ProxyTests {
    @Test("auth, routing and framing")
    func framing() async throws {
        let proxy = EngineProxy(apiKey: "secret") { request in
            if request.path == "/echo" {
                return ProxyReply(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { c in
                    c.yield(Data("data: ".utf8)); c.yield(request.body); c.yield(Data("\n\n".utf8)); c.finish()
                })
            }
            if request.path == "/fail" {
                return ProxyReply(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { c in
                    c.finish(throwing: ProxyHTTPError(status: 413, message: "big"))
                })
            }
            return .error(status: 404, "nf")
        }
        let port = try proxy.start()
        defer { proxy.stop() }
        let unauth = await request(port, post("/echo", key: nil, body: "{}"))
        #expect(unauth.hasPrefix("HTTP/1.1 401"))
        let wrong = await request(port, post("/echo", key: "secreT", body: "{}"))
        #expect(wrong.hasPrefix("HTTP/1.1 401"))
        let ok = await request(port, post("/echo", key: "secret", body: "{\"a\":\"日本\"}"))
        #expect(ok.hasPrefix("HTTP/1.1 200"))
        #expect(ok.contains("Content-Type: text/event-stream"))
        #expect(ok.hasSuffix("\r\n\r\ndata: {\"a\":\"日本\"}\n\n"))
        let nf = await request(port, post("/nope", key: "secret", body: ""))
        #expect(nf.hasPrefix("HTTP/1.1 404"))
        let failed = await request(port, post("/fail", key: "secret", body: ""))
        #expect(failed.hasPrefix("HTTP/1.1 413"))
        let chunked = await request(port, "POST /echo HTTP/1.1\r\nAuthorization: Bearer secret\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        #expect(chunked.hasPrefix("HTTP/1.1 411"))
        let garbage = await request(port, "hello\r\n\r\n")
        #expect(garbage.hasPrefix("HTTP/1.1 400"))
        // Body split across packets.
        let split = await Task.detached { () -> String in
            let fd = connectTo(port)
            sendRaw(fd, "POST /echo HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: 10\r\n\r\n01234")
            usleep(100_000)
            sendRaw(fd, "56789")
            return readAll(fd)
        }.value
        #expect(split.hasSuffix("data: 0123456789\n\n"))
    }

    @Test("pieces reach the client while the body is still streaming")
    func incremental() async throws {
        let proxy = EngineProxy(apiKey: "k") { _ in
            ProxyReply(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { c in
                Task {
                    c.yield(Data("data: first\n\n".utf8))
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    c.yield(Data("data: [DONE]\n\n".utf8))
                    c.finish()
                }
            })
        }
        let port = try proxy.start()
        defer { proxy.stop() }
        let (firstAt, all) = await Task.detached { () -> (Double, String) in
            let start = Date()
            let fd = connectTo(port)
            sendRaw(fd, post("/v1/completions", key: "k", body: "{}"))
            var buf = [UInt8](repeating: 0, count: 4096)
            var got: [UInt8] = []
            var firstAt = -1.0
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                got.append(contentsOf: buf[0..<n])
                if firstAt < 0, String(decoding: got, as: UTF8.self).contains("first") { firstAt = Date().timeIntervalSince(start) }
            }
            close(fd)
            return (firstAt, String(decoding: got, as: UTF8.self))
        }.value
        #expect(firstAt >= 0 && firstAt < 0.5)
        #expect(all.hasSuffix("data: [DONE]\n\n"))
    }

    @Test("closing the client cancels the work and releases the slot")
    func disconnectCancels() async throws {
        let slots = EngineSlots(capacity: 1)
        let cancelled = Flag()
        let upstreamClosed = Flag()
        let proxy = EngineProxy(apiKey: "k") { _ in
            ProxyReply(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { c in
                let task = Task {
                    do {
                        try await EngineRequestRunner.run(
                            priority: .pdf, slots: slots,
                            ensureRunning: { true }, isServing: { _ in true },
                            open: {
                                EngineAttempt(stream: AsyncThrowingStream<Data, Error> { up in
                                    let t = Task {
                                        up.yield(Data("data: a\n\n".utf8))
                                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                                        up.finish()
                                    }
                                    up.onTermination = { _ in upstreamClosed.bump(); t.cancel() }
                                }, generation: 0)
                            },
                            yield: { _ = c.yield($0) })
                        c.finish()
                    } catch {
                        if error is CancellationError { cancelled.bump() }
                        c.finish(throwing: error)
                    }
                }
                c.onTermination = { _ in task.cancel() }
            })
        }
        let port = try proxy.start()
        defer { proxy.stop() }
        await Task.detached {
            let fd = connectTo(port)
            sendRaw(fd, post("/v1/completions", key: "k", body: "{}"))
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = recv(fd, &buf, buf.count, 0)
            close(fd)
        }.value
        var waited = 0
        while (await slots.inFlight != 0 || upstreamClosed.count == 0), waited < 40 {
            try await Task.sleep(nanoseconds: 50_000_000); waited += 1
        }
        #expect(await slots.inFlight == 0)
        #expect(upstreamClosed.count == 1)
        #expect(cancelled.count == 1)
        // The slot is usable again at once.
        let ticket = try await slots.acquire(.interactive)
        await slots.release(ticket)
    }

    @Test("PDF traffic through the proxy waits behind an interactive request")
    func priorityAcrossProxy() async throws {
        let slots = EngineSlots(capacity: 1)
        let order = Log()
        let proxy = EngineProxy(apiKey: "k") { request in
            ProxyReply(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { c in
                let name = String(decoding: request.body, as: UTF8.self)
                Task {
                    try? await EngineRequestRunner.run(priority: .pdf, slots: slots,
                        ensureRunning: { true }, isServing: { _ in true },
                        open: { await order.add(name); return EngineAttempt(stream: AsyncThrowingStream<Data, Error> { $0.yield(Data(name.utf8)); $0.finish() }, generation: 0) },
                        yield: { _ = c.yield($0) })
                    c.finish()
                }
            })
        }
        let port = try proxy.start()
        defer { proxy.stop() }
        let hold = try await slots.acquire(.pdf)
        let pdf = Task { await request(port, post("/v1/completions", key: "k", body: "pdf")) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let interactive = Task {
            try await EngineRequestRunner.run(priority: .interactive, slots: slots,
                ensureRunning: { true }, isServing: { _ in true },
                open: { await order.add("interactive"); return EngineAttempt(stream: AsyncThrowingStream<Data, Error> { $0.finish() }, generation: 0) },
                yield: { _ in })
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await slots.waiting == 2)
        await slots.release(hold)
        try await interactive.value
        let reply = await pdf.value
        #expect(reply.hasSuffix("pdf"))
        #expect(await order.items == ["interactive", "pdf"])
    }

    @Test("stop ends the listener")
    func stops() async throws {
        let proxy = EngineProxy(apiKey: "k") { _ in .error(status: 404, "x") }
        let port = try proxy.start()
        proxy.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        let fd = socket(AF_INET, streamSocket, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        close(fd)
        #expect(r != 0)
    }
}
