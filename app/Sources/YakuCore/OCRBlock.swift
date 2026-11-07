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
///   - the two lines' heights are within 15% of each other,
///   - their left edges line up, or they overlap horizontally.
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
    /// M5 tried tightening this to 15% to keep a UI row's title and its
    /// description apart (they differ by 12–14%, so they merge). It cannot work:
    /// the lines of a real paragraph differ by up to 21% — Vision's line box
    /// grows with ascenders and descenders — so any tolerance that splits the
    /// title/description pair also splits paragraphs. See `M5.md` for the
    /// measurements; the rule is left at the specification's 25%.
    public static let heightTolerance: CGFloat = 0.25
    /// The overlap rule: at least half of the narrower line.
    public static let overlapRatio: CGFloat = 0.5
    /// How far two left edges may differ and still count as lined up.
    public static let alignmentRatio: CGFloat = 0.5

    public static func blocks(from lines: [OCRLine]) -> [OCRBlock] {
        let candidates = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Reading order: top to bottom, then left to right.
        let sorted = candidates.sorted { first, second in
            first.rect.minY == second.rect.minY
                ? first.rect.minX < second.rect.minX
                : first.rect.minY < second.rect.minY
        }

        var groups: [[OCRLine]] = []
        for line in sorted {
            // The open block this line continues most closely, if any.
            var bestIndex: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for (index, group) in groups.enumerated() {
                guard let last = group.last, follows(line, last) else { continue }
                let gap = max(0, line.rect.minY - last.rect.maxY)
                if gap < bestGap {
                    bestGap = gap
                    bestIndex = index
                }
            }
            if let bestIndex {
                groups[bestIndex].append(line)
            } else {
                groups.append([line])
            }
        }

        let built = groups
            .compactMap { group -> OCRBlock? in
                let ordered = group.sorted { $0.rect.minY < $1.rect.minY }
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

    /// Whether `line` follows `last` under all three of the specification's
    /// rules.
    public static func follows(_ line: OCRLine, _ last: OCRLine) -> Bool {
        let lastHeight = last.rect.height
        let height = line.rect.height
        guard lastHeight > 0, height > 0, last.rect.width > 0, line.rect.width > 0 else { return false }

        guard abs(lastHeight - height) <= heightTolerance * max(lastHeight, height) else { return false }

        let gap = line.rect.minY - last.rect.maxY
        guard gap <= gapRatio * min(lastHeight, height) else { return false }

        let aligned = abs(line.rect.minX - last.rect.minX) <= alignmentRatio * min(lastHeight, height)
        let overlap = horizontalOverlap(last.rect, line.rect)
        let overlapping = overlap >= overlapRatio * min(last.rect.width, line.rect.width)
        return aligned || overlapping
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
