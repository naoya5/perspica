import CoreGraphics
import Foundation

/// How a translation was sized to sit on top of one block (SPEC 4.6 の 3).
public struct OverlayTextLayout: Sendable, Equatable {
    /// The size the translation is drawn at, in points.
    public let fontSize: CGFloat
    /// The scale applied to the original line's font size (1.0 ... minimum).
    public let scale: CGFloat
    /// The width the translation was fitted into: the block's own width, or
    /// wider when a one-line block had room to the right and the translation
    /// needed it. The backing is drawn at this width.
    public let width: CGFloat
    /// The height the translation needs at that size and width.
    public let textHeight: CGFloat
    /// How far the translation sticks out below the block, 0 when it fits.
    public let overflow: CGFloat

    public init(fontSize: CGFloat, scale: CGFloat, width: CGFloat, textHeight: CGFloat, overflow: CGFloat) {
        self.fontSize = fontSize
        self.scale = scale
        self.width = width
        self.textHeight = textHeight
        self.overflow = overflow
    }
}

/// Sizes a translation to the block it covers (SPEC 4.6 の 3).
///
/// The text starts at the original line's size. A block of **one line** (a UI
/// row's title or a sidebar's label) may first grow to the right instead of
/// wrapping, up to the width the caller allows, so a translation longer than
/// the original label stays on one line instead of being shrunk until it breaks
/// mid-word (measured: `プライバシー` at 13.8pt needed 81pt in a 48pt box, and
/// the old order drew it at 10.1pt, broken before the ー). If it still does not
/// fit, or the block is several lines tall and keeps its own width, the text is
/// stepped down to the minimum (the settings' 「重ねる文字の最小の大きさ」, 70%
/// by default). If it still does not fit it is allowed to spill out of the
/// bottom, which the caller shows by stretching the backing.
public enum OverlayTextFit {
    /// The step the size is reduced by: 5% of the original each time.
    public static let scaleStep: CGFloat = 0.05
    /// The settings' default floor (SPEC 4.4 の 画面翻訳).
    public static let defaultMinimumScale: CGFloat = 0.7
    /// A line's height is about 1.2 × its font size.
    public static let lineHeightToFontSize: CGFloat = 1.2
    public static let minimumFontSize: CGFloat = 8
    /// A width no line of text reaches, used to ask `measure` for the height of
    /// one line at a size (the font's own line height, rounding included).
    public static let oneLineProbeWidth: CGFloat = 100_000

    /// The font size that matches a line's measured height.
    public static func originalFontSize(forLineHeight height: CGFloat) -> CGFloat {
        max(minimumFontSize, height / lineHeightToFontSize)
    }

    /// Picks the largest size (from the original down to `minimumScale`) at
    /// which `text` fits. `measure(text, width, size)` returns the height the
    /// text needs at that width and font size, so the caller's own text layout
    /// decides.
    ///
    /// `widenTo` is the widest a **one-line** block may grow to the right (nil
    /// for a block that keeps its own width). With it, "fits" means "fits on one
    /// line", and the narrowest width that does so is returned, so the backing
    /// covers no more of the picture than it has to.
    public static func layout(
        text: String,
        blockSize: CGSize,
        originalFontSize: CGFloat,
        minimumScale: CGFloat = defaultMinimumScale,
        widenTo: CGFloat? = nil,
        measure: (String, CGFloat, CGFloat) -> CGFloat
    ) -> OverlayTextLayout {
        let floor = min(max(minimumScale, 0.1), 1.0)
        let width = max(blockSize.width, 1)
        let limit = widenTo.map { max($0, width) }

        var candidate: CGFloat = 1.0
        while candidate >= floor - 1e-6 {
            let size = originalFontSize * candidate
            if let limit {
                // One line is the whole point here, so the target is the font's
                // own line height rather than the box, which Vision reports as
                // the ink and is a little shorter than a line.
                let target = max(blockSize.height, measure(text, oneLineProbeWidth, size))
                if let fitted = oneLineWidth(
                    text, from: width, to: limit, size: size, height: target, measure: measure
                ) {
                    return OverlayTextLayout(
                        fontSize: size,
                        scale: candidate,
                        width: fitted,
                        textHeight: measure(text, fitted, size),
                        overflow: 0
                    )
                }
            } else {
                let height = measure(text, width, size)
                if height <= blockSize.height {
                    return OverlayTextLayout(
                        fontSize: size,
                        scale: candidate,
                        width: width,
                        textHeight: height,
                        overflow: 0
                    )
                }
            }
            candidate -= scaleStep
        }

        // The floor, and it still does not fit: the text wraps in the room it
        // was given and the backing grows downward.
        let size = originalFontSize * floor
        let target = max(blockSize.height, measure(text, oneLineProbeWidth, size))
        let fallbackWidth = limit.map {
            legalWrapWidth(text, upTo: $0, atLeast: width, size: size, height: target, measure: measure)
        } ?? width
        let height = measure(text, fallbackWidth, size)
        return OverlayTextLayout(
            fontSize: size,
            scale: floor,
            width: fallbackWidth,
            textHeight: height,
            overflow: max(0, height - blockSize.height)
        )
    }

    /// The narrowest width between `minimum` and `maximum` at which `text` is
    /// one line of at most `height`, or nil when it cannot be even at
    /// `maximum`. The height falls as the width grows, so a bisection finds it.
    static func oneLineWidth(
        _ text: String,
        from minimum: CGFloat,
        to maximum: CGFloat,
        size: CGFloat,
        height: CGFloat,
        measure: (String, CGFloat, CGFloat) -> CGFloat
    ) -> CGFloat? {
        if measure(text, minimum, size) <= height { return minimum }
        guard measure(text, maximum, size) <= height else { return nil }
        var narrow = minimum
        var wide = maximum
        for _ in 0..<12 {
            let middle = (narrow + wide) / 2
            if measure(text, middle, size) <= height {
                wide = middle
            } else {
                narrow = middle
            }
        }
        return wide
    }

    /// The characters a line may not begin with (SPEC 4.6 の 3 の禁則): the
    /// prolonged sound mark, the small kana, and closing punctuation. Breaking
    /// before one of these strands it at the start of the next line, which is
    /// what the overlay used to draw (`プライバシ` / `ー`).
    public static let lineStartForbidden = "ー〜～ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ々ヽヾゝゞ、。，．,.:;：；!！?？)）]］}｝」』】〕〉》”’"

    /// Whether a line may not begin with this character.
    public static func isLineStartForbidden(_ character: Character) -> Bool {
        lineStartForbidden.contains(character)
    }

    /// The number of characters of `text` that fit on the first line at this
    /// width and size. Bisection avoids shaping every prefix of a long
    /// translation, using at most eighteen measurements.
    static func firstLineCount(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        height: CGFloat,
        measure: (String, CGFloat, CGFloat) -> CGFloat
    ) -> Int {
        let characters = Array(text)
        var best = 0
        var low = 1
        var high = characters.count
        for _ in 0..<18 {
            guard low <= high else { break }
            let count = low + (high - low) / 2
            if measure(String(characters.prefix(count)), width, size) <= height {
                best = count
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }

    /// The width to wrap `text` at so that no line begins with a character that
    /// may not begin one, or `maximum` when the wrap there is already legal (or
    /// no better width is found).
    ///
    /// Only reached when a one-line block cannot fit on one line even at the
    /// floor. The break is moved one character earlier until it is legal, and
    /// the width is set to the narrowest that still holds that many characters,
    /// so the line breaks exactly there — that is the 「まず縮める」 of SPEC
    /// 4.6 の 3: give up room rather than strand the character.
    ///
    /// Never narrower than `atLeast`, the block's own width: the backing is
    /// drawn at the returned width, so a narrower one would leave the original
    /// text showing at the sides. Where the two disagree the wrap is left at
    /// the block's width, because the size is already at its floor.
    static func legalWrapWidth(
        _ text: String,
        upTo maximum: CGFloat,
        atLeast floorWidth: CGFloat,
        size: CGFloat,
        height: CGFloat,
        measure: (String, CGFloat, CGFloat) -> CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return maximum }
        let greedy = firstLineCount(text, width: maximum, size: size, height: height, measure: measure)
        // The whole text fits on one line, or nothing fits: nothing to fix.
        guard greedy > 0, greedy < text.count else { return maximum }
        guard isLineStartForbidden(text[text.index(text.startIndex, offsetBy: greedy)]) else {
            return maximum
        }
        // Move the break earlier until the next line starts on a legal
        // character. Two characters are always separable, so this ends.
        var count = greedy - 1
        while count > 1, isLineStartForbidden(text[text.index(text.startIndex, offsetBy: count)]) {
            count -= 1
        }
        guard let needed = oneLineWidth(
            String(text.prefix(count)),
            from: 1,
            to: maximum,
            size: size,
            height: height,
            measure: measure
        ) else { return maximum }
        return min(max(needed, min(floorWidth, maximum)), maximum)
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
