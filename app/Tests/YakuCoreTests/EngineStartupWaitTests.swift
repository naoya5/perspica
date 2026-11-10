// The 15 s startup limit at its exact boundary, with a pretend clock.
import Foundation
import Testing
@testable import YakuCore

private actor FakeClock {
    var t: TimeInterval = 0
    var probes: [TimeInterval] = []
    func now() -> Date { Date(timeIntervalSinceReferenceDate: t) }
    func advance(_ s: TimeInterval) { t += s }
    func noteProbe(_ timeout: TimeInterval) { probes.append(timeout) }
}

@Suite("EngineStartupWait")
struct EngineStartupWaitTests {
    static let limit: TimeInterval = 15
    static var deadline: Date { Date(timeIntervalSinceReferenceDate: limit) }
    /// Within a nanosecond of the limit, and never past it.
    static func atLimit(_ end: TimeInterval) -> Bool { end <= limit + 1e-9 && end >= limit - 1e-9 }

    /// `answer(t)` is the status a probe started at time t would get and how
    /// long it takes; a probe gives up after its timeout, unless `honorsTimeout`
    /// is false (a client that overruns).
    private func run(
        honorsTimeout: Bool = true,
        alive: Bool = true,
        _ answer: @escaping @Sendable (TimeInterval) -> (Int?, TimeInterval)
    ) async -> (EngineStartupWait.Outcome, TimeInterval, [TimeInterval]) {
        let clock = FakeClock()
        let outcome = await EngineStartupWait.waitForReady(
            deadline: Self.deadline,
            now: { await clock.now() },
            probe: { timeout in
                await clock.noteProbe(timeout)
                let (status, latency) = answer(await clock.t)
                if honorsTimeout, latency > timeout {
                    await clock.advance(timeout)
                    return nil
                }
                await clock.advance(latency)
                return status
            },
            isAlive: { alive },
            sleep: { await clock.advance($0) }
        )
        return (outcome, await clock.t, await clock.probes)
    }

    @Test("ready just before the limit is accepted")
    func readyBefore() async {
        let (outcome, end, _) = await run { t in t >= 14.9 ? (200, 0.01) : (503, 0.01) }
        #expect(outcome == .ready)
        #expect(end <= Self.limit)
    }

    @Test("a 200 arriving exactly at 15 s counts")
    func readyAtBoundary() async {
        let (outcome, end, _) = await run { t in t >= 14.5 ? (200, Self.limit - t) : (503, 0.5) }
        #expect(outcome == .ready)
        #expect(Self.atLimit(end))
    }

    @Test("a slow 200 is cut off at 15 s, not accepted a second later")
    func slowAnswerCutOff() async {
        let (outcome, end, probes) = await run { t in t >= 14.5 ? (200, 1.0) : (503, 0.5) }
        #expect(outcome == .timedOut)
        #expect(Self.atLimit(end))
        #expect(probes.allSatisfy { $0 > 0 && $0 <= EngineStartupWait.probeTimeout })
        #expect(probes.last! <= 0.5 + 1e-9)
    }

    @Test("a client that overruns its timeout still cannot pass the limit")
    func overrunRejected() async {
        let (outcome, end, _) = await run(honorsTimeout: false) { t in t >= 14.5 ? (200, 0.7) : (503, 0.5) }
        #expect(outcome == .timedOut)
        #expect(end > Self.limit)   // the late answer arrived, and was refused
    }

    @Test("503 throughout fails at exactly 15 s")
    func loadingForever() async {
        let (outcome, end, _) = await run { _ in (503, 0.3) }
        #expect(outcome == .timedOut)
        #expect(Self.atLimit(end))
    }

    @Test("unreachable throughout fails at exactly 15 s")
    func unreachableForever() async {
        let (outcome, end, _) = await run { _ in (nil, 5) }
        #expect(outcome == .timedOut)
        #expect(Self.atLimit(end))
    }

    @Test("an engine that exits is a startup death, not a timeout")
    func died() async {
        let (outcome, end, _) = await run(alive: false) { _ in (nil, 0.01) }
        #expect(outcome == .died)
        #expect(end < 1)
    }
}
