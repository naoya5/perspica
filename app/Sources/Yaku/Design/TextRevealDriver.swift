import Foundation
import Observation

/// Drives the character-by-character reveal of arriving translation text
/// (SPEC 4.2 / 6.5).
///
/// The obvious implementation — `withAnimation(.easeOut(duration: 0.14))` on
/// every arriving piece — makes SwiftUI render every display frame for as long
/// as pieces keep arriving. On a 120Hz display that measured about 11% CPU for
/// a single translation, because each new animation restarted before the
/// previous one finished.
///
/// This driver instead advances a plain value at 30Hz while there is text left
/// to reveal, so the number of renders is bounded no matter how fast the model
/// streams. Characters still take 140ms each; a burst is spread over at most
/// 0.3s so the reveal stays visible without lagging behind.
@MainActor
@Observable
final class TextRevealDriver {
    /// How many characters are visible. `FadeInTextRenderer` reads this.
    private(set) var revealed: Double = 0

    /// Renders per second while text is arriving.
    static let tickRate: Double = 30
    /// How long one character takes to appear.
    static let perCharacter: Double = 0.14
    /// The longest a burst of characters may take in total.
    static let maximumBurst: Double = 0.30

    private var target: Int = 0
    private var rate: Double = 0
    @ObservationIgnored private var timer: Timer?

    /// Called whenever the translation text changes.
    func update(count: Int) {
        if Double(count) < revealed {
            // New text replaced the old one; show it from the start.
            revealed = Double(count)
            target = count
            stopTimer()
            return
        }
        guard count > target || count > Int(revealed) else { return }

        // The rate must cover the whole remaining distance, not just this
        // piece: a burst that arrives while the reveal is already behind would
        // otherwise take far longer than the burst lasts. (An earlier version
        // computed the rate from the newest piece alone and settled at 10
        // characters a second, so the timer never caught up and never stopped.)
        let remaining = max(Double(count) - revealed, 1)
        let duration = min(Self.perCharacter * remaining, Self.maximumBurst)
        rate = remaining / duration
        target = count
        startTimerIfNeeded()
    }

    /// Jumps to the end, used when a state is restored rather than streamed.
    func finish(to count: Int) {
        revealed = Double(count)
        target = count
        stopTimer()
    }

    func stop() {
        stopTimer()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // The timer invalidates itself if the driver goes away, so a view that
        // is torn down cannot leave a repeating timer running.
        let timer = Timer(timeInterval: 1 / Self.tickRate, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let remaining = Double(target) - revealed
        guard remaining > 0 else {
            revealed = Double(target)
            stopTimer()
            return
        }
        revealed = min(Double(target), revealed + rate / Self.tickRate)
    }
}
