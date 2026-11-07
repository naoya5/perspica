import CoreGraphics
import Foundation

/// How a translation was sized to sit on top of one block (SPEC 4.6 の 3).
public struct OverlayTextLayout: Sendable, Equatable {
    /// The size the translation is drawn at, in points.
    public let fontSize: CGFloat
    /// The scale applied to the original line's font size (1.0 ... minimum).
    public let scale: CGFloat
    /// The height the translation needs at that size and the block's width.
    public let textHeight: CGFloat
    /// How far the translation sticks out below the block, 0 when it fits.
    public let overflow: CGFloat

    public init(fontSize: CGFloat, scale: CGFloat, textHeight: CGFloat, overflow: CGFloat) {
        self.fontSize = fontSize
        self.scale = scale
        self.textHeight = textHeight
        self.overflow = overflow
    }
}

/// Sizes a translation to the block it covers (SPEC 4.6 の 3).
///
/// The text starts at the original line's size and is stepped down until it
/// fits the block, but no further than the minimum (the settings' 「重ねる文字の
/// 最小の大きさ」, 70% by default). If it still does not fit it is allowed to
/// spill out of the bottom, which the caller shows by stretching the backing.
public enum OverlayTextFit {
    /// The step the size is reduced by: 5% of the original each time.
    public static let scaleStep: CGFloat = 0.05
    /// The settings' default floor (SPEC 4.4 の 画面翻訳).
    public static let defaultMinimumScale: CGFloat = 0.7
    /// A line's height is about 1.2 × its font size.
    public static let lineHeightToFontSize: CGFloat = 1.2
    public static let minimumFontSize: CGFloat = 8

    /// The font size that matches a line's measured height.
    public static func originalFontSize(forLineHeight height: CGFloat) -> CGFloat {
        max(minimumFontSize, height / lineHeightToFontSize)
    }

    /// Picks the largest size (from the original down to `minimumScale`) whose
    /// text fits `blockSize.height`. `measure` returns the height the text needs
    /// at a given width and font size, so the caller's own text layout decides.
    public static func layout(
        blockSize: CGSize,
        originalFontSize: CGFloat,
        minimumScale: CGFloat = defaultMinimumScale,
        measure: (CGFloat, CGFloat) -> CGFloat
    ) -> OverlayTextLayout {
        let floor = min(max(minimumScale, 0.1), 1.0)
        let width = max(blockSize.width, 1)

        var candidate: CGFloat = 1.0
        while candidate >= floor - 1e-6 {
            let height = measure(width, originalFontSize * candidate)
            if height <= blockSize.height {
                return OverlayTextLayout(
                    fontSize: originalFontSize * candidate,
                    scale: candidate,
                    textHeight: height,
                    overflow: 0
                )
            }
            candidate -= scaleStep
        }

        let height = measure(width, originalFontSize * floor)
        return OverlayTextLayout(
            fontSize: originalFontSize * floor,
            scale: floor,
            textHeight: height,
            overflow: max(0, height - blockSize.height)
        )
    }
}

/// Builds the context a screen block is translated with (SPEC 5.2 の F4).
public enum OverlayContext {
    /// The specification's ceiling for the whole context.
    public static let limit = 600

    /// The other blocks read from the same screen, in reading order, cut off at
    /// `limit` characters. The block being translated is left out.
    public static func context(forIndex index: Int, in texts: [String], limit: Int = limit) -> String {
        var pieces: [String] = []
        for (other, text) in texts.enumerated() where other != index {
            let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            pieces.append(piece)
        }
        let joined = pieces.joined(separator: " ")
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit))
    }
}
