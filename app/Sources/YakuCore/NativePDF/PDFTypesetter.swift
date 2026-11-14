import CoreGraphics
import CoreText
import Foundation

// Typesets a translated paragraph into the box its English original occupied.

/// One paragraph to typeset.
public struct PDFTypesetInput: Sendable {
    /// A piece of the paragraph, in reading order.
    public enum Piece: Sendable, Equatable {
        case text(String)
        /// An inline object of this size whose baseline sits `descent` above its bottom edge.
        case inline(id: Int, size: CGSize, descent: CGFloat)
    }

    /// Horizontal alignment of the typeset lines.
    public enum Alignment: Sendable {
        case natural, center
    }

    public var pieces: [Piece]
    /// The original paragraph bounds (page space, y up).
    public var box: CGRect
    /// The largest area the text may grow into (contains `box`).
    public var maxBox: CGRect
    /// The original dominant font size.
    public var fontSize: CGFloat
    /// The original number of lines, used to guess the original line spacing.
    public var lineCount: Int
    public var serif: Bool
    public var bold: Bool
    public var alignment: Alignment
    public var color: PDFColor
    /// How far the original first line started right of `box.minX` (an indent, or room
    /// for a footnote mark that stays on the page).
    public var firstLineIndent: CGFloat

    public init(pieces: [Piece], box: CGRect, maxBox: CGRect, fontSize: CGFloat, lineCount: Int,
                serif: Bool, bold: Bool, alignment: Alignment, color: PDFColor = .black,
                firstLineIndent: CGFloat = 0) {
        self.pieces = pieces
        self.box = box
        self.maxBox = maxBox
        self.fontSize = fontSize
        self.lineCount = lineCount
        self.serif = serif
        self.bold = bold
        self.alignment = alignment
        self.color = color
        self.firstLineIndent = firstLineIndent
    }
}

/// What the typesetter decided.
public struct PDFTypesetResult: Sendable {
    /// The chosen font size.
    public var fontSize: CGFloat
    /// The area actually covered by the text.
    public var usedRect: CGRect
    /// Where each inline object must be drawn (page space, y up).
    public var inlinePlacements: [Int: CGRect]
    /// True when even the minimum size did not fit `maxBox`.
    public var overflowed: Bool

    public init(fontSize: CGFloat, usedRect: CGRect, inlinePlacements: [Int: CGRect], overflowed: Bool) {
        self.fontSize = fontSize
        self.usedRect = usedRect
        self.inlinePlacements = inlinePlacements
        self.overflowed = overflowed
    }
}

public enum PDFTypesetter {
    /// Lays out without drawing. Pure and deterministic.
    public static func layout(_ input: PDFTypesetInput) -> PDFTypesetResult {
        solve(input).result
    }

    /// Lays out and draws the text into `context`. Inline objects are not drawn; the caller draws
    /// them at `inlinePlacements`.
    public static func draw(_ input: PDFTypesetInput, in context: CGContext) -> PDFTypesetResult {
        let solved = solve(input)
        let textMatrix = context.textMatrix
        context.saveGState()
        context.textMatrix = .identity
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // A paragraph may not paint over its neighbours, so even the overflow case stays
        // inside the area the caller allowed.
        context.clip(to: input.maxBox)
        CTFrameDraw(solved.layout.frame, context)
        context.restoreGState()
        // Quartz keeps the text matrix outside the graphics state, so restore it by hand.
        context.textMatrix = textMatrix
        return solved.result
    }
}

// MARK: - Sizing

extension PDFTypesetter {
    /// The floor of the size search: half the original size, never below 4 pt.
    private static func minimumSize(_ input: PDFTypesetInput) -> CGFloat {
        max(4, input.fontSize * 0.5)
    }

    /// Distance between two baselines. The original leading is honoured as long as it stays
    /// inside the range that keeps Japanese readable at the chosen size.
    private static func lineAdvance(_ input: PDFTypesetInput, size: CGFloat) -> CGFloat {
        let original = input.lineCount > 1 ? input.box.height / CGFloat(input.lineCount) : input.fontSize * 1.2
        return min(max(original, size * 1.15), size * 1.5)
    }

    private static func font(size: CGFloat, serif: Bool, bold: Bool) -> CTFont {
        let name: String
        switch (serif, bold) {
        case (true, false): name = "HiraMinProN-W3"
        case (true, true): name = "HiraMinProN-W6"
        case (false, false): name = "HiraginoSans-W3"
        case (false, true): name = "HiraginoSans-W6"
        }
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func solve(_ input: PDFTypesetInput) -> (result: PDFTypesetResult, layout: PDFTypesetLayout) {
        let minimum = minimumSize(input)
        let start = max(input.fontSize, minimum)
        // A cut of more than 15% makes a paragraph look out of place next to its
        // neighbours, so below 85% the text first uses the free space under the box.
        let shrinkLimit = max(start * 0.85, minimum)
        let growLimit = max(input.box.maxY - input.maxBox.minY, input.box.height)

        func height(at size: CGFloat) -> CGFloat {
            buildLayout(input, size: size).usedRect.height
        }

        var chosen = largestFitting(in: shrinkLimit...start, limit: input.box.height, height: height)
        if chosen == nil {
            chosen = largestFitting(in: minimum...shrinkLimit, limit: growLimit, height: height)
        }
        let overflowed = chosen == nil
        let size = chosen ?? minimum
        let layout = buildLayout(input, size: size)
        let result = PDFTypesetResult(fontSize: size, usedRect: layout.usedRect,
                                      inlinePlacements: layout.inlinePlacements, overflowed: overflowed)
        return (result, layout)
    }

    /// The largest size whose text height stays within `limit`. Line height grows as the size
    /// shrinks, so the search is monotone enough for bisection; the returned size was measured
    /// and does fit.
    private static func largestFitting(in range: ClosedRange<CGFloat>, limit: CGFloat,
                                       height: (CGFloat) -> CGFloat) -> CGFloat? {
        if height(range.upperBound) <= limit { return range.upperBound }
        if height(range.lowerBound) > limit { return nil }
        var low = range.lowerBound
        var high = range.upperBound
        // Eight steps resolve the range to well under a tenth of a point.
        for _ in 0..<8 {
            let middle = (low + high) / 2
            if height(middle) <= limit { low = middle } else { high = middle }
        }
        return low
    }
}

// MARK: - CoreText layout

/// A laid out paragraph. Internal so the tests can inspect the lines CoreText produced.
struct PDFTypesetLayout {
    let attributed: NSAttributedString
    let frame: CTFrame
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let usedRect: CGRect
    let inlinePlacements: [Int: CGRect]
}

/// An inline object reserved by a run delegate.
private final class PDFInlineBox {
    let id: Int
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(id: Int, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.id = id
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

// Run delegate callbacks are C function pointers and cannot capture state, so they read the
// box through the delegate's refCon. The attributed string keeps the box alive.
private func inlineAscent(_ ref: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<PDFInlineBox>.fromOpaque(ref).takeUnretainedValue().ascent
}

private func inlineDescent(_ ref: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<PDFInlineBox>.fromOpaque(ref).takeUnretainedValue().descent
}

private func inlineWidth(_ ref: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<PDFInlineBox>.fromOpaque(ref).takeUnretainedValue().width
}

// The box is owned by the attributed string, so the delegate has nothing to release.
private func inlineRelease(_ ref: UnsafeMutableRawPointer) {}

private let inlineBoxAttribute = NSAttributedString.Key("YakuInlineBox")

extension PDFTypesetter {
    /// Builds the CoreText frame for `input` at `size`. Exposed for tests, which inspect the
    /// lines to check line breaking and inline placement.
    static func buildLayout(_ input: PDFTypesetInput, size: CGFloat) -> PDFTypesetLayout {
        let font = font(size: size, serif: input.serif, bold: input.bold)
        let advance = lineAdvance(input, size: size)
        // A line holding a tall inline formula (a fraction) gets the height it needs,
        // otherwise the formula would overlap the line above.
        let tallestInline = input.pieces.reduce(CGFloat(0)) { tallest, piece in
            if case .inline(_, let size, _) = piece { return max(tallest, size.height) }
            return tallest
        }
        let style = paragraphStyle(advance: advance, maximum: max(advance, tallestInline * 1.15),
                                   leading: CTFontGetLeading(font), alignment: input.alignment,
                                   firstLineIndent: min(max(input.firstLineIndent, 0), input.box.width / 2))
        let attributed = attributedText(input, font: font, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Every line holds at least one character, so this height can never clip a line.
        let height = CGFloat(max(attributed.length, 1)) * advance + advance
        // The path's top edge is the box's top edge: CoreText starts the first line there,
        // which keeps the paragraph anchored to the original top.
        let pathRect = CGRect(x: input.box.minX, y: input.box.maxY - height,
                              width: input.box.width, height: height)
        let path = CGPath(rect: pathRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        // CoreText reports line origins relative to the path's bounding box, so shift them
        // into page space.
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
            for index in origins.indices {
                origins[index].x += pathRect.minX
                origins[index].y += pathRect.minY
            }
        }

        var used = CGRect.null
        var placements: [Int: CGRect] = [:]
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            used = used.union(CGRect(x: origins[index].x, y: origins[index].y - descent,
                                     width: width, height: ascent + descent))
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0, range.length > 0, range.location < attributed.length,
                      let box = attributed.attribute(inlineBoxAttribute, at: range.location,
                                                     effectiveRange: nil) as? PDFInlineBox
                else { continue }
                let offset = CTLineGetOffsetForStringIndex(line, range.location, nil)
                placements[box.id] = CGRect(x: origins[index].x + offset,
                                            y: origins[index].y - box.descent,
                                            width: box.width, height: box.ascent + box.descent)
            }
        }
        if used.isNull {
            used = CGRect(x: input.box.minX, y: input.box.maxY, width: 0, height: 0)
        }
        return PDFTypesetLayout(attributed: attributed, frame: frame, lines: lines,
                                lineOrigins: origins, usedRect: used, inlinePlacements: placements)
    }

    private static func attributedText(_ input: PDFTypesetInput, font: CTFont,
                                       style: CTParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): input.color.cgColor,
        ]
        let result = NSMutableAttributedString()
        for piece in input.pieces {
            switch piece {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: base))
            case .inline(let id, let size, let descent):
                let box = PDFInlineBox(id: id, width: max(size.width, 0),
                                       ascent: max(size.height - descent, 0), descent: max(descent, 0))
                var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                                                       dealloc: inlineRelease,
                                                       getAscent: inlineAscent, getDescent: inlineDescent,
                                                       getWidth: inlineWidth)
                guard let delegate = CTRunDelegateCreate(&callbacks,
                                                         Unmanaged.passUnretained(box).toOpaque())
                else {
                    result.append(NSAttributedString(string: "\u{FFFC}", attributes: base))
                    continue
                }
                var attributes = base
                attributes[inlineBoxAttribute] = box
                attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            }
        }
        return result
    }

    /// Fixed line height plus a negative line spacing adjustment: CoreText adds the font's own
    /// leading to every line height, and that leading has to be cancelled for the advance to be
    /// the one we chose.
    private static func paragraphStyle(advance: CGFloat, maximum: CGFloat, leading: CGFloat,
                                       alignment: PDFTypesetInput.Alignment,
                                       firstLineIndent: CGFloat) -> CTParagraphStyle {
        var lineHeight = advance
        var maximumHeight = maximum
        var adjustment = -leading
        var indent = alignment == .center ? 0 : firstLineIndent
        var textAlignment: CTTextAlignment = alignment == .center ? .center : .left
        return withUnsafeBytes(of: &lineHeight) { height in
            withUnsafeBytes(of: &maximumHeight) { maximumPointer in
            withUnsafeBytes(of: &indent) { indentPointer in
            withUnsafeBytes(of: &adjustment) { spacing in
                withUnsafeBytes(of: &textAlignment) { align in
                    let settings = [
                        CTParagraphStyleSetting(spec: .minimumLineHeight,
                                                valueSize: MemoryLayout<CGFloat>.size,
                                                value: height.baseAddress!),
                        CTParagraphStyleSetting(spec: .maximumLineHeight,
                                                valueSize: MemoryLayout<CGFloat>.size,
                                                value: maximumPointer.baseAddress!),
                        CTParagraphStyleSetting(spec: .firstLineHeadIndent,
                                                valueSize: MemoryLayout<CGFloat>.size,
                                                value: indentPointer.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                valueSize: MemoryLayout<CGFloat>.size,
                                                value: spacing.baseAddress!),
                        CTParagraphStyleSetting(spec: .alignment,
                                                valueSize: MemoryLayout<CTTextAlignment>.size,
                                                value: align.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
            }
            }
        }
    }
}
