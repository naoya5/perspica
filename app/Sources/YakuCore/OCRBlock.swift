import CoreGraphics
import Foundation

/// One line of text Vision recognised (SPEC 9).
///
/// `rect` is in the captured image's pixels with the origin at the **top left**,
/// which is the coordinate system the overlay places its blocks in. Vision's
/// own boxes are normalised with the origin at the bottom left, so the reader in
/// `Sources/Yaku/System` flips them before they arrive here.
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let rect: CGRect
    /// Vision's confidence for the line, 0...1.
    public let confidence: Double

    public init(text: String, rect: CGRect, confidence: Double) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

/// A run of lines that read as one piece of text, with the source joined up
/// (SPEC 9).
public struct OCRBlock: Sendable, Equatable {
    /// The lines whose text is used; lines under the confidence floor are not
    /// here.
    public let lines: [OCRLine]
    /// The block's text: the lines joined, with a line-break hyphen removed.
    public let text: String
    /// The extent of the whole run, including any line dropped for low
    /// confidence, in image pixels (top-left origin).
    public let rect: CGRect

    public init(lines: [OCRLine]) {
        self.init(lines: lines, rect: lines.reduce(CGRect.null) { $0.union($1.rect) })
    }

    public init(lines: [OCRLine], rect: CGRect) {
        self.lines = lines
        self.text = OCRBlockBuilder.join(lines)
        self.rect = rect
    }

    /// The lowest confidence among the lines, so a shaky block can be spotted.
    public var confidence: Double { lines.map(\.confidence).min() ?? 0 }

    /// The median height of one line, in image pixels. The overlay sizes its
    /// text from this, not from the block, which is several lines tall.
    public var lineHeight: CGFloat {
        let heights = lines.map(\.rect.height).sorted()
        guard !heights.isEmpty else { return rect.height }
        return heights[heights.count / 2]
    }
}

/// Groups recognised lines into blocks and joins their text (SPEC 9).
///
/// The three rules are the specification's: a line joins the block above it when
/// **all** of these hold.
///   - the vertical gap is at most 0.8 × the line height,
///   - the two lines' heights are within 25% of each other,
///   - their left edges line up, or they overlap horizontally.
///
/// Four further rules change those verdicts, all measured from the samples. A
/// line whose **text** reads as the continuation of the sentence above is a
/// wrapped line whatever its box says (`continuesSentence`) — that is the one
/// that matters on a real screen, because a short continuation line with no
/// ascender or descender comes back in a box a third shorter than its
/// predecessor's and used to be cut off and translated on its own. A much
/// shorter line above a longer one is a row of its own rather than a wrapped one
/// (`lineLengthRatio`), and two lines drawn at noticeably different sizes are
/// separate runs even when their widths match (`sizeTolerance`).
///
/// Each line is compared against the last line of every open block rather than
/// only the previous line. That is what keeps a two-column page in two blocks
/// instead of splitting every line apart.
///
/// A line below the confidence floor still takes part in the grouping, so a
/// single garbled line does not break a paragraph in two; it is left out of the
/// text and the block keeps the whole run's extent.
public enum OCRBlockBuilder {
    /// Lines below this confidence are dropped (SPEC 9).
    public static let minimumConfidence = 0.3
    /// The gap rule: 0.8 × the line height.
    public static let gapRatio: CGFloat = 0.8
    /// The height rule: within 25%.
    ///
    /// Tightening this to 15% was tried to keep a UI row's title and its
    /// description apart (they differ by 12–14%, so they merge). It cannot work:
    /// the lines of a real paragraph differ by up to 21% — Vision's line box
    /// grows with ascenders and descenders — so any tolerance that splits the
    /// title/description pair also splits paragraphs. The rule is left at the
    /// specification's 25%.
    public static let heightTolerance: CGFloat = 0.25
    /// The overlap rule: at least half of the narrower line.
    public static let overlapRatio: CGFloat = 0.5
    /// How far two left edges may differ and still count as lined up.
    public static let alignmentRatio: CGFloat = 0.5
    /// The line-length rule: a line shorter than this share of the line below
    /// it is a line of its own, not a wrapped one.
    ///
    /// A UI row is a short title above a long description, and the two are
    /// separate rows rather than one wrapped sentence. Their heights cannot
    /// tell them apart (a paragraph's own lines differ by up to 21%, a
    /// title/description pair by 12–14% — see `heightTolerance`), but their
    /// lengths can.
    ///
    /// Measured over every pair the three rules above would join, in the
    /// whole-picture and the tiled pass of the article, two-column and UI
    /// samples: a wrapped line's line above is 0.92–5.02 × its
    /// width, and the two title/description pairs are at 0.45 and 0.56. 0.7
    /// sits in the gap, 0.22 from either side.
    ///
    /// The third UI row, `Show in Lock Screen` over `Keep recent items
    /// visible`, is at 1.01 and no width rule can split it; the size rule below
    /// is what keeps them apart.
    ///
    /// A paragraph's last line is short but has no line below it, so it is
    /// unaffected; that is what keeps a paragraph in one block (measured: the
    /// article stays 5 blocks and the two-column sample 5).
    public static let lineLengthRatio: CGFloat = 0.7

    /// The size rule: two lines whose measured sizes differ by more than this
    /// share are separate runs, not one wrapped paragraph.
    ///
    /// The line-length rule above cannot split a UI row whose title and
    /// description are about the same width. The UI sample's third row is one:
    /// `Show in Lock Screen` is 146.5px over `Keep recent items visible` at
    /// 144.4px, a ratio of 1.01, yet they are drawn at 15 and 12 points. Their
    /// sizes tell them apart where their widths do not.
    ///
    /// The sizes must be **comparable across scripts**, which the ink band is
    /// not (it follows the x-height of Latin text and the taller em box of
    /// Japanese text, and read a mixed sample's Japanese lines 35–46% larger
    /// than its English ones at one size). `TextInk.fontSize(in:line:text:)` —
    /// the ink's width against the recognised text's width — is, and the
    /// numbers below are its readings over the whole-picture pass, as a share
    /// of the larger of the two:
    ///
    /// | lines | difference |
    /// |---|---|
    /// | the article's paragraph lines (Latin, 19pt) | 0.0–0.1% |
    /// | the two-column sample's paragraph lines (Latin, 17pt) | 0.2–0.3% |
    /// | a paragraph mixing Japanese and English lines (17pt) | **1.1%** |
    /// | the UI sample's title over description (15 / 12pt) | **19.7%** |
    ///
    /// 8% sits in the gap: 7× the worst run that must stay together, 2.5× below
    /// the pair that must come apart.
    public static let sizeTolerance: CGFloat = 0.08

    /// How far a wrapped line may be indented from the line above and still
    /// count as the same paragraph, as a share of the taller line's height.
    ///
    /// A bullet's continuation line starts under the bullet's text rather than
    /// under the marker, so its left edge is a marker's width to the right of
    /// the line above. `alignmentRatio` alone reads that as "not lined up", and
    /// it is only the horizontal-overlap rule that used to save such a pair. A
    /// marker is a couple of characters wide, so 4 × the line height is a
    /// generous ceiling that still cannot reach the next column.
    public static let hangingIndentRatio: CGFloat = 4

    /// The punctuation a sentence ends with. A line that ends with one of these
    /// starts a new sentence, so the line below it is not a continuation.
    public static let sentenceEnders = ".!?:;。！？：；…"

    /// The marks that may sit after a sentence-ending punctuation mark without
    /// changing the fact that the sentence ended (`(see the plan.)`).
    public static let closingMarks = "\"'”’)]}）］｝」』】〕〉》"

    /// The characters a bullet or a dash list item begins with.
    public static let bulletMarkers = "•‣▪▫◦·※*+–—-"

    /// Whether `line` reads as the continuation of `last`'s sentence, which is
    /// what a wrapped line looks like (SPEC 9).
    ///
    /// The rule is the one a reader uses: the line above does not end a
    /// sentence, and this line starts with a lower-case letter, so the sentence
    /// is still going. A line that opens a new list item is never a
    /// continuation, however it starts.
    ///
    /// This is the signal the geometry cannot give. A short continuation line
    /// with no ascender and no descender — `the work.`, `one outcome.` — comes
    /// back from Vision in a box about a third shorter than the line above it,
    /// which is more than `heightTolerance` allows, so the fragment was cut off
    /// and translated alone. Japanese is unaffected: its characters
    /// have no case, so the rule never fires and the height rule, which works
    /// well for CJK, decides.
    public static func continuesSentence(_ line: OCRLine, _ last: OCRLine) -> Bool {
        let above = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let below = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !above.isEmpty, !below.isEmpty else { return false }
        guard !endsSentence(above) else { return false }
        guard !opensListItem(below) else { return false }
        return below.first?.isLowercase ?? false
    }

    /// Whether the text ends a sentence, ignoring any closing mark after the
    /// punctuation (`… the plan.)`).
    public static func endsSentence(_ text: String) -> Bool {
        var characters = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = characters.last, closingMarks.contains(last) {
            characters = characters.dropLast()
        }
        guard let last = characters.last else { return false }
        return sentenceEnders.contains(last)
    }

    /// Whether the text opens a new list item rather than continuing the line
    /// above: a bullet, a dash, or a number or single letter followed by `.` or
    /// `)` — `•`, `-`, `1.`, `2)`, `a.`.
    public static func opensListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if bulletMarkers.contains(first) { return true }
        guard first.isNumber || (first.isLetter && first.isLowercase) else { return false }
        // At most three characters: `1.`, `12.`, `a)`, `1)`.
        let prefix = trimmed.prefix(3)
        guard prefix.count >= 2 else { return false }
        let after = prefix[prefix.index(after: prefix.startIndex)]
        return after == "." || after == ")"
    }

    /// Groups lines into blocks, optionally told how large each line's text was
    /// (in any consistent unit — only the ratio between two lines is used).
    ///
    /// `sizeOf` returns nil when the size cannot be measured, and the size rule
    /// is then skipped for that line: the caller passes `TextInk`'s reading of
    /// the picture, which needs the picture, so a caller without one keeps the
    /// geometry-only grouping.
    public static func blocks(from lines: [OCRLine], sizeOf: (OCRLine) -> CGFloat? = { _ in nil }) -> [OCRBlock] {
        let candidates = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (line: $0, size: sizeOf($0)) }
        // Reading order: top to bottom, then left to right.
        let sorted = candidates.sorted { first, second in
            first.line.rect.minY == second.line.rect.minY
                ? first.line.rect.minX < second.line.rect.minX
                : first.line.rect.minY < second.line.rect.minY
        }

        var groups: [[Int]] = []
        for (index, item) in sorted.enumerated() {
            // The open block this line continues most closely, if any.
            var bestIndex: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for (groupIndex, group) in groups.enumerated() {
                guard let lastIndex = group.last else { continue }
                let last = sorted[lastIndex]
                guard follows(item.line, last.line, size: item.size, lastSize: last.size) else { continue }
                let gap = max(0, item.line.rect.minY - last.line.rect.maxY)
                if gap < bestGap {
                    bestGap = gap
                    bestIndex = groupIndex
                }
            }
            if let bestIndex {
                groups[bestIndex].append(index)
            } else {
                groups.append([index])
            }
        }

        let built = groups
            .compactMap { group -> OCRBlock? in
                let ordered = group.map { sorted[$0].line }.sorted { $0.rect.minY < $1.rect.minY }
                let confident = ordered.filter { $0.confidence >= minimumConfidence }
                // Nothing readable in this run: leave it alone.
                guard !confident.isEmpty else { return nil }
                let rect = ordered.reduce(CGRect.null) { $0.union($1.rect) }
                return OCRBlock(lines: confident, rect: rect)
            }
        // Reading order: top to bottom, but column by column when the page is
        // laid out in two columns (SPEC 9, `OverlayReadingOrder`).
        return OverlayReadingOrder.arrange(built)
    }

    /// Whether `line` follows `last` under all of the specification's rules.
    ///
    /// `size` and `lastSize` are the two lines' measured text sizes, in any
    /// consistent unit; leave them nil to apply the geometric rules alone.
    ///
    /// A line whose text reads as a wrapped continuation
    /// (`continuesSentence`) is treated as one: the height rule, the
    /// hanging-indent rule and the two split rules are then waived, because
    /// they all rest on Vision's box and the text is a better witness than the
    /// box is. The size rule is waived with them, so a continuation is never
    /// cut off by a size that was misread; the cost is that a UI row whose
    /// description happens to begin in lower case would join its title, which
    /// none of the samples does.
    public static func follows(
        _ line: OCRLine,
        _ last: OCRLine,
        size: CGFloat? = nil,
        lastSize: CGFloat? = nil
    ) -> Bool {
        let lastHeight = last.rect.height
        let height = line.rect.height
        guard lastHeight > 0, height > 0, last.rect.width > 0, line.rect.width > 0 else { return false }

        let wrapped = continuesSentence(line, last)
        let taller = max(lastHeight, height)
        let shorter = min(lastHeight, height)

        guard wrapped || abs(lastHeight - height) <= heightTolerance * taller else { return false }

        let gap = line.rect.minY - last.rect.maxY
        guard gap <= gapRatio * (wrapped ? taller : shorter) else { return false }

        let aligned = abs(line.rect.minX - last.rect.minX) <= alignmentRatio * (wrapped ? taller : shorter)
        let overlap = horizontalOverlap(last.rect, line.rect)
        let overlapping = overlap >= overlapRatio * min(last.rect.width, line.rect.width)
        // A wrapped line's own indent: the second line of a bullet starts under
        // the bullet's text, to the right of the line above and no further than
        // a marker's width.
        let indent = line.rect.minX - last.rect.minX
        let hanging = wrapped && indent >= -1 && indent <= hangingIndentRatio * taller
        guard aligned || overlapping || hanging else { return false }

        // A much shorter line above a longer one is a line of its own, not a
        // wrapped one (a UI row's title above its description). Checked after
        // the rules above, so it only ever splits a pair they would have joined.
        guard wrapped || last.rect.width >= lineLengthRatio * line.rect.width else { return false }

        // Two lines drawn at noticeably different sizes are separate runs even
        // when their widths match (a UI row whose title and description happen
        // to be the same length). See `sizeTolerance`.
        if !wrapped, let size, let lastSize {
            let largest = max(size, lastSize)
            if largest > 0 {
                guard abs(size - lastSize) <= sizeTolerance * largest else { return false }
            }
        }
        return true
    }

    /// The width two rectangles share horizontally (0 when they are apart).
    public static func horizontalOverlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        max(0, min(first.maxX, second.maxX) - max(first.minX, second.minX))
    }

    /// Joins a block's lines into one string.
    ///
    /// A line ending in a hyphen is joined to the next without it (SPEC 9). Two
    /// CJK characters are joined with no space; anything else gets a space.
    public static func join(_ lines: [OCRLine]) -> String {
        var result = ""
        for line in lines {
            let piece = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if result.isEmpty {
                result = piece
                continue
            }
            if result.hasSuffix("-") {
                result.removeLast()
                result += piece
            } else if isCJK(result.last) || isCJK(piece.first) {
                result += piece
            } else {
                result += " " + piece
            }
        }
        return result
    }

    /// True for characters that are written without spaces between them.
    public static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x309F, // hiragana
             0x30A0...0x30FF, // katakana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // full-width forms
             0xAC00...0xD7AF: // hangul syllables
            return true
        default:
            return false
        }
    }
}
