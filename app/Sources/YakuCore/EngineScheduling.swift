import Foundation

/// SPEC 7.3: 対話（F1・F2）> 画面（F4）> PDF（F3）.
public enum EnginePriority: Int, Sendable, Comparable, CaseIterable {
    case pdf = 0
    case screen = 1
    case interactive = 2

    public static func < (lhs: EnginePriority, rhs: EnginePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why a scheduled request could not be served.
public enum EngineStreamError: Error, Equatable, Sendable {
    /// The engine could not be started. The app maps this to SPEC 13's
    /// start failure (or the missing model) message.
    case startFailed
    /// The engine stopped during the request, and the one restart SPEC 7.1
    /// allows did not help (or output had already been shown).
    case engineStopped
    /// The prompt cannot fit in one slot's 4,096 tokens even without its
    /// optional sections.
    case requestTooLarge
}

/// The engine's four request slots (`--parallel 4`), shared by every caller:
/// the panel, the HUD, the manager, the screen overlay and, through the
/// loopback proxy, the PDF worker (SPEC 7.3).
///
/// A free slot goes to the waiting request with the highest priority, in
/// arrival order within one priority. A request that is already running is
/// never interrupted; the newest-only rule for dialogue requests is the
/// caller's cancellation.
public actor EngineSlots {
    public struct Ticket: Sendable, Hashable {
        fileprivate let id: UInt64
        public let priority: EnginePriority
    }

    private struct Waiter {
        let id: UInt64
        let priority: EnginePriority
        let continuation: CheckedContinuation<Ticket, Error>
    }

    public let capacity: Int
    private var running: Set<UInt64> = []
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    public init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    public var inFlight: Int { running.count }
    public var waiting: Int { waiters.count }
    public func waitingCount(_ priority: EnginePriority) -> Int {
        waiters.filter { $0.priority == priority }.count
    }

    /// Waits for a slot. Throws `CancellationError` if the task is cancelled
    /// while waiting; no slot is held then.
    public func acquire(_ priority: EnginePriority) async throws -> Ticket {
        nextID += 1
        let id = nextID
        if Task.isCancelled { throw CancellationError() }
        if running.count < capacity, !waiters.contains(where: { $0.priority >= priority }) {
            running.insert(id)
            return Ticket(id: id, priority: priority)
        }
        return try await withTaskCancellationHandler {
            // The body runs on this actor before the call suspends, so the
            // waiter is stored before `cancelWaiter` (a later actor job) can
            // look for it; a cancel that finds nothing came after the grant.
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release(_ ticket: Ticket) {
        guard running.remove(ticket.id) != nil else { return }
        grant()
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func grant() {
        while running.count < capacity, !waiters.isEmpty {
            var best = 0
            for index in waiters.indices where waiters[index].priority > waiters[best].priority {
                best = index
            }
            let waiter = waiters.remove(at: best)
            running.insert(waiter.id)
            waiter.continuation.resume(returning: Ticket(id: waiter.id, priority: waiter.priority))
        }
    }
}

/// One opened upstream request and the engine instance it went to.
public struct EngineAttempt<Element: Sendable>: Sendable {
    public let stream: AsyncThrowingStream<Element, Error>
    /// Changes every time the engine is started, so a failure can be told
    /// apart from a restart another request has already made.
    public let generation: UInt64

    public init(stream: AsyncThrowingStream<Element, Error>, generation: UInt64) {
        self.stream = stream
        self.generation = generation
    }
}

/// The policy every engine request follows, whatever its caller: hold one of
/// the shared slots for the whole request, start the engine if it is not
/// running, and when the engine dies before the request produced anything,
/// start it once more and retry (SPEC 7.1: 1 回だけ起こし直す。また落ちたら失敗).
///
/// After an element has been yielded nothing is sent again, so a consumer
/// that appends every element never sees text twice; a failure then ends the
/// request with `EngineStreamError.engineStopped`.
public enum EngineRequestRunner {
    public static func run<Element: Sendable>(
        priority: EnginePriority,
        slots: EngineSlots,
        ensureRunning: @Sendable () async -> Bool,
        isServing: @Sendable (_ generation: UInt64) async -> Bool,
        open: @Sendable () async throws -> EngineAttempt<Element>,
        onRestart: @Sendable () async -> Void = {},
        yield: @Sendable (Element) async throws -> Void
    ) async throws {
        let ticket = try await slots.acquire(priority)
        do {
            try await attempt(
                ensureRunning: ensureRunning,
                isServing: isServing,
                open: open,
                onRestart: onRestart,
                yield: yield
            )
            await slots.release(ticket)
        } catch {
            await slots.release(ticket)
            throw error
        }
    }

    private static func attempt<Element: Sendable>(
        ensureRunning: @Sendable () async -> Bool,
        isServing: @Sendable (UInt64) async -> Bool,
        open: @Sendable () async throws -> EngineAttempt<Element>,
        onRestart: @Sendable () async -> Void,
        yield: @Sendable (Element) async throws -> Void
    ) async throws {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard await ensureRunning() else {
                // A start failure on the retry means the engine fell over
                // again: that is the "また落ちたら" failure.
                throw attempt == 0 ? EngineStreamError.startFailed : EngineStreamError.engineStopped
            }
            try Task.checkCancellation()
            var produced = false
            var generation: UInt64?
            do {
                let opened = try await open()
                generation = opened.generation
                for try await element in opened.stream {
                    try Task.checkCancellation()
                    produced = true
                    try await yield(element)
                }
                try Task.checkCancellation()
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if produced { throw EngineStreamError.engineStopped }
                if error as? EngineStreamError == .requestTooLarge { throw error }
                // `open` failed before reaching an engine: only "no engine to
                // send to" is a crash; a bad request is not resent.
                if generation == nil, error as? EngineStreamError != .engineStopped { throw error }
                // The engine that took the request is still the one serving:
                // the failure is the request's own, not a crash.
                if let generation, await isServing(generation) { throw error }
            }
            if attempt == 0 { await onRestart() }
        }
        throw EngineStreamError.engineStopped
    }
}

/// What one `GET /health` showed about the engine.
public enum EngineHealthProbe: Sendable, Equatable {
    /// The server answered (200 ready; 503 loading or busy).
    case status(Int)
    /// Nothing listens on the port any more: the engine is gone.
    case refused
    /// No answer in time. A busy engine looks like this too.
    case timedOut
}

/// Decides whether a failed request's engine died. Only definite evidence
/// counts: the server process is gone, or its port refuses connections. A
/// slow answer from a live process is not a crash, because forgetting that
/// engine kills it and aborts every other request it is serving.
public enum EngineLiveness {
    public static let firstProbeTimeout: TimeInterval = 1
    public static let secondProbeTimeout: TimeInterval = 3

    /// `pidAlive` is nil when the server's pid is not known.
    public static func isAlive(
        pidAlive: @Sendable () async -> Bool?,
        probe: @Sendable (TimeInterval) async -> EngineHealthProbe
    ) async -> Bool {
        if await pidAlive() == false { return false }
        switch await probe(firstProbeTimeout) {
        case .status: return true
        case .refused: return false
        case .timedOut: break
        }
        if await pidAlive() == false { return false }
        return await probe(secondProbeTimeout) != .refused
    }
}
