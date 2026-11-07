import SwiftUI

/// Reveals arriving text character by character: each character fades from
/// 0 to 1 opacity and from 3px of blur to none (SPEC 4.2, 6.5).
///
/// This is a `TextRenderer`, so the whole translation stays a single `Text`
/// and is laid out normally. The prototype put one `Text` per arriving chunk
/// inside a custom layout, which is what made a chunk break onto its own line.
///
/// `revealed` is the number of characters that have arrived; SwiftUI animates
/// it because `TextRenderer` refines `Animatable`.
struct FadeInTextRenderer: TextRenderer, Animatable {
    var revealed: Double
    var blurRadius: Double = 3

    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                let count = run.count
                defer { index += count }
                guard count > 0 else { continue }

                // Characters already revealed are drawn as one slice, so the
                // font shaping of the settled text is untouched.
                let settled = min(max(Int(revealed.rounded(.down)) - index, 0), count)
                if settled > 0 {
                    context.draw(run[0..<settled])
                }

                // The single character the reveal is passing over right now.
                guard settled < count else { continue }
                let progress = min(max(revealed - Double(index + settled), 0), 1)
                guard progress > 0 else { continue }
                var fading = context
                fading.opacity = progress
                fading.addFilter(.blur(radius: (1 - progress) * blurRadius))
                fading.draw(run[settled..<(settled + 1)])
            }
        }
    }
}
