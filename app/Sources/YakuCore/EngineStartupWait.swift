import Foundation

/// SPEC 7.1: the engine can serve once `GET /health` answers 200; if that has
/// not happened within the startup limit, the start has failed. The limit is
/// exact: every probe and pause is clamped to the time left, and a 200 that
/// arrives after the deadline does not count.
public enum EngineStartupWait {
    public enum Outcome: Equatable, Sendable {
        case ready
        case died
        case timedOut
        case cancelled
    }

    public static let probeTimeout: TimeInterval = 1
    public static let pollInterval: TimeInterval = 0.05

    public static func waitForReady(
        deadline: Date,
        now: @Sendable () async -> Date = { Date() },
        probe: @Sendable (_ timeout: TimeInterval) async -> Int?,
        isAlive: @Sendable () async -> Bool,
        sleep: @Sendable (_ seconds: TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onLoading: @Sendable () async -> Void = {}
    ) async -> Outcome {
        var loadingReported = false
        while true {
            if Task.isCancelled { return .cancelled }
            let left = deadline.timeIntervalSince(await now())
            guard left > 0 else { return .timedOut }
            let status = await probe(min(probeTimeout, left))
            if Task.isCancelled { return .cancelled }
            let answeredInTime = await now() <= deadline
            if status == 200, answeredInTime { return .ready }
            if status == 503, !loadingReported {
                loadingReported = true
                await onLoading()
            }
            if !(await isAlive()) { return .died }
            let remaining = deadline.timeIntervalSince(await now())
            guard remaining > 0 else { return .timedOut }
            await sleep(min(pollInterval, remaining))
        }
    }
}
