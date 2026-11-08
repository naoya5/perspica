import CoreGraphics
import Foundation

/// Decides whether a recognised block was written in a heavy weight, so the
/// overlay can put its translation back in that weight (SPEC 4.6 の 3).
///
/// Vision does not report a font weight, so the weight is measured from the
/// picture: a bold line lays down more ink for its height than a regular one.
/// The ratio of ink pixels to the block's area separates the samples cleanly —
/// a 40-point bold heading measured 0.37 and a 20-point bold title 0.36, while
/// regular body text sat at 0.20–0.27 — with one caveat: a short regular line
/// can reach 0.32 on its own (round letters, a capital), so a second, weaker
/// ink threshold only counts when the line is also taller than the page's
/// typical line.
public enum OverlayEmphasis {
    /// At or above this much ink, the line is bold whatever its size.
    public static let strongInkRatio: Double = 0.33
    /// Below the strong threshold but at or above this, a line counts as bold
    /// only when it is also taller than the page's usual line.
    public static let mediumInkRatio: Double = 0.28
    /// How much taller than the page's median line a line must be for the
    /// weaker ink threshold to apply.
    public static let tallLineRatio: Double = 1.15
    /// Very short strings give a noisy ratio, so they are never called bold on
    /// ink alone.
    public static let minimumCharacters = 4
    /// A pixel counts as ink when its luminance differs from the block's
    /// background by more than this (the same rule the text colour uses).
    public static let inkContrast: Double = 0.24

    /// Whether the block's original text was heavy.
    ///
    /// - Parameters:
    ///   - rect: the block's box in image pixels (top-left origin).
    ///   - text: the text read from it.
    ///   - lineHeight: the block's median line height in image pixels.
    ///   - medianLineHeight: the median line height across the page's blocks.
    public static func isBold(
        in image: PixelImage,
        block rect: CGRect,
        text: String,
        lineHeight: CGFloat,
        medianLineHeight: CGFloat
    ) -> Bool {
        guard text.count >= minimumCharacters, lineHeight > 0 else { return false }
        let ratio = inkRatio(in: image, block: rect)
        if ratio >= strongInkRatio { return true }
        if ratio >= mediumInkRatio, medianLineHeight > 0,
           lineHeight >= medianLineHeight * tallLineRatio {
            return true
        }
        return false
    }

    /// The share of the block's area that is text ink.
    public static func inkRatio(in image: PixelImage, block rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let x1 = min(image.width - 1, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let y1 = min(image.height - 1, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }

        // The background is the block's median luminance; the text is whatever
        // sits away from it, on either side (`TextInk.isInk`).
        var luminances: [Double] = []
        luminances.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1) / 4)
        for y in stride(from: y0, through: y1, by: 2) {
            for x in stride(from: x0, through: x1, by: 2) {
                luminances.append(image.luminance(x: x, y: y))
            }
        }
        guard !luminances.isEmpty else { return 0 }
        let sorted = luminances.sorted()
        let background = sorted[sorted.count / 2]

        var ink = 0
        var total = 0
        for y in y0...y1 {
            for x in x0...x1 {
                total += 1
                if TextInk.isInk(image.luminance(x: x, y: y), background: background) { ink += 1 }
            }
        }
        return total > 0 ? Double(ink) / Double(total) : 0
    }
}
