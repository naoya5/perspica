import CoreGraphics
import Foundation

/// How strongly a glyph reads as mathematics.
///
/// Weak symbols (hyphen, brackets, comma) only continue a formula that a strong
/// symbol started. That keeps "dot-product" from turning into an inline formula
/// while still letting "(Q, K, V)" stay part of the formula it belongs to.
enum LayoutMathStrength: Int, Sendable, Comparable {
    case none = 0
    case weak = 1
    case strong = 2

    static func < (lhs: LayoutMathStrength, rhs: LayoutMathStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A glyph with the facts layout analysis needs, computed once.
struct LayoutGlyph: Sendable {
    let index: Int
    let unicode: String
    let origin: CGPoint
    let fontSize: CGFloat
    let style: PDFFontStyle
    let box: CGRect
    let isSpace: Bool
    let isLetter: Bool
    let math: LayoutMathStrength
}

/// The role a line plays before it is merged into a paragraph.
enum LayoutLineClass: Sendable, Equatable {
    case text, heading, caption, formula, furniture, other
}

/// One visual line: glyphs sharing a baseline, split at column gutters.
struct LayoutLine: Sendable {
    var glyphs: [LayoutGlyph]
    var baseline: CGFloat
    var fontSize: CGFloat
    var bounds: CGRect
    var text: String
    var style: PDFFontStyle
    var strongMath: Int
    var weakMath: Int
    var nonSpace: Int
    var letters: Int
    /// Spans separated by gaps wide enough to be table cells.
    var cells: Int
    var lineClass: LayoutLineClass
    var hint: Int?
    /// This piece continues the piece before it on the same baseline: a formula
    /// chunk set beside the text line it belongs to.
    var continues: Bool = false
    /// Small stacked math glyphs folded into this line (an inline fraction's
    /// denominator, a stacked script), one array per absorbed fragment line.
    /// They belong to a formula segment of the line but are not part of its text.
    var fragments: [[LayoutGlyph]] = []
}

enum PDFLayoutGlyphs {
    /// Glyphs that put ink on the page. Render modes 3 and 7 draw nothing, and a
    /// glyph without text and without advance has neither shape nor position.
    /// Rotated text is left out too: its boxes would cut across horizontal lines,
    /// and it stays on the page untouched.
    static func prepare(_ glyphs: [PDFGlyph]) -> [LayoutGlyph] {
        var out: [LayoutGlyph] = []
        out.reserveCapacity(glyphs.count)
        for (index, glyph) in glyphs.enumerated() {
            guard glyph.renderMode != 3, glyph.renderMode != 7, glyph.isUpright else { continue }
            guard !glyph.unicode.isEmpty || glyph.advance != 0 else { continue }
            let size = glyph.fontSize > 0 ? glyph.fontSize : 1
            let box = CGRect(x: min(glyph.origin.x, glyph.origin.x + glyph.advance),
                             y: glyph.origin.y - size * 0.22,
                             width: abs(glyph.advance), height: size)
            var isSpace = false
            var isLetter = false
            var math = LayoutMathStrength.none
            if let scalar = glyph.unicode.unicodeScalars.first {
                isSpace = glyph.unicode.allSatisfy(\.isWhitespace)
                isLetter = glyph.unicode.contains(where: \.isLetter)
                math = mathStrength(of: scalar, style: glyph.style)
            }
            out.append(LayoutGlyph(index: index, unicode: glyph.unicode, origin: glyph.origin,
                                   fontSize: size, style: glyph.style, box: box,
                                   isSpace: isSpace, isLetter: isLetter, math: math))
        }
        return out
    }

    /// Groups glyphs into lines: similar baseline first, then a split wherever the
    /// horizontal gap is wide enough to be a gutter between columns.
    static func lines(from glyphs: [LayoutGlyph]) -> [LayoutLine] {
        let sorted = glyphs.sorted { lhs, rhs in
            if lhs.origin.y != rhs.origin.y { return lhs.origin.y > rhs.origin.y }
            return lhs.box.minX < rhs.box.minX
        }
        var clusters: [[LayoutGlyph]] = []
        var references: [(baseline: CGFloat, size: CGFloat)] = []
        for glyph in sorted {
            var best: Int?
            var bestDelta = CGFloat.infinity
            for (i, reference) in references.enumerated() {
                let delta = abs(reference.baseline - glyph.origin.y)
                // The smaller of the two sizes keeps a tall radical from pulling in
                // the next line while still letting sub- and superscripts join.
                let tolerance = 0.6 * min(reference.size, glyph.fontSize)
                if delta <= tolerance, delta < bestDelta {
                    best = i
                    bestDelta = delta
                }
            }
            if let i = best {
                clusters[i].append(glyph)
                if glyph.fontSize > references[i].size {
                    references[i] = (glyph.origin.y, glyph.fontSize)
                }
            } else {
                clusters.append([glyph])
                references.append((glyph.origin.y, glyph.fontSize))
            }
        }
        moveHangingSigns(&clusters)
        var out: [LayoutLine] = []
        for cluster in clusters where !cluster.isEmpty {
            out.append(contentsOf: split(cluster))
        }
        out.sort { lhs, rhs in
            if lhs.baseline != rhs.baseline { return lhs.baseline > rhs.baseline }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        return out
    }

    /// Signs that TeX hangs from a point above the line they belong to.
    private static let hangingSigns: Set<String> = [
        "√", "∑", "∏", "∐", "∫", "∮", "⋃", "⋂", "⋀", "⋁", "⨀", "⨁", "⨂", "⨄", "⨆",
    ]

    /// A radical sign hangs from above its radicand, and a big operator such as ∑
    /// hangs from above its operand, so the origin can sit nearer the line above
    /// than its own line. The sign belongs with the glyph that starts right after
    /// it: that glyph's line is where the radicand or the operand is.
    private static func moveHangingSigns(_ clusters: inout [[LayoutGlyph]]) {
        for source in clusters.indices {
            for radical in clusters[source] where hangingSigns.contains(radical.unicode) {
                // A big operator reaches further down than a radical sign.
                let depth: CGFloat = radical.unicode == "√" ? 1.2 : 1.5
                let reach = max(radical.fontSize * 0.3, 1)
                // In a display formula the sign bridges its own line (the fraction bar's
                // line); taking it away would open a gap that splits that line.
                let others = clusters[source].filter { !$0.isSpace && $0.index != radical.index }
                let left = others.filter { $0.box.midX <= radical.box.midX }.map(\.box.maxX).max()
                let right = others.filter { $0.box.midX > radical.box.midX }.map(\.box.minX).min()
                if let left, let right, right - left > radical.fontSize * 1.5 { continue }
                // Followers on other lines: (cluster, horizontal gap).
                var followers: [(cluster: Int, gap: CGFloat)] = []
                for candidate in clusters.indices where candidate != source {
                    for glyph in clusters[candidate] where !glyph.isSpace {
                        let gap = glyph.box.minX - radical.box.maxX
                        guard gap >= -reach, gap <= reach,
                              // The radicand's baseline is at or below the sign's origin,
                              // within about one size: the sign reaches down to it.
                              glyph.origin.y <= radical.origin.y + reach,
                              glyph.origin.y >= radical.origin.y - radical.fontSize * depth else { continue }
                        // Only move when the follower is not already on the radical's own line.
                        let ownFollower = clusters[source].contains { other in
                            !other.isSpace && other.index != radical.index
                                && abs(other.box.minX - radical.box.maxX) <= abs(gap)
                        }
                        if ownFollower { continue }
                        followers.append((candidate, abs(gap)))
                    }
                }
                // The operand's line is a full cluster; a limit such as the d_k above
                // a ∑ is a small cluster of its own that joins that line later.
                func size(_ cluster: Int) -> Int { clusters[cluster].filter { !$0.isSpace }.count }
                let target = followers.min { lhs, rhs in
                    let (left, right) = (size(lhs.cluster), size(rhs.cluster))
                    return left != right ? left > right : lhs.gap < rhs.gap
                }?.cluster
                if let target {
                    clusters[source].removeAll { $0.index == radical.index }
                    clusters[target].append(radical)
                }
            }
        }
    }

    /// Splits one baseline cluster at wide gaps and keeps an equation number with
    /// the formula it numbers.
    private static func split(_ cluster: [LayoutGlyph]) -> [LayoutLine] {
        let ordered = cluster.sorted { $0.box.minX < $1.box.minX }
        let size = dominantFontSize(ordered)
        let gutter = 2.0 * size
        var groups: [[LayoutGlyph]] = []
        var current: [LayoutGlyph] = []
        var rightEdge = -CGFloat.infinity
        for glyph in ordered {
            if !current.isEmpty, glyph.box.minX - rightEdge > gutter {
                groups.append(current)
                current = []
                rightEdge = -CGFloat.infinity
            }
            current.append(glyph)
            rightEdge = max(rightEdge, glyph.box.maxX)
        }
        if !current.isEmpty { groups.append(current) }
        // A row of three or more short cells is a table row, not a gutter: keep it
        // whole so that the row can be recognised as a grid.
        if groups.count >= 3 {
            let low = groups.first!.first!.box.minX
            let high = groups.last!.map(\.box.maxX).max() ?? low
            let total = high - low
            let narrow = groups.allSatisfy { group in
                let width = (group.map(\.box.maxX).max() ?? low) - (group.first!.box.minX)
                return width < 0.3 * total
            }
            if narrow { groups = [groups.flatMap { $0 }] }
        }
        // "(1)" set at the right margin belongs to the formula to its left.
        if groups.count >= 2, isEquationNumber(groups[groups.count - 1]),
           groups[groups.count - 2].contains(where: { $0.math == .strong }) {
            let number = groups.removeLast()
            groups[groups.count - 1].append(contentsOf: number)
        }
        return groups.map(makeLine)
    }

    private static func isEquationNumber(_ glyphs: [LayoutGlyph]) -> Bool {
        let text = glyphs.filter { !$0.isSpace }.map(\.unicode).joined()
        guard text.count >= 3, text.hasPrefix("("), text.hasSuffix(")") else { return false }
        let inner = text.dropFirst().dropLast()
        guard (1...2).contains(inner.count) else { return false }
        return inner.allSatisfy { $0.isNumber || $0.isLetter }
    }

    private static func makeLine(_ glyphs: [LayoutGlyph]) -> LayoutLine {
        let size = dominantFontSize(glyphs)
        var box = CGRect.null
        var strong = 0
        var weak = 0
        var nonSpace = 0
        var letters = 0
        var baselines: [CGFloat] = []
        for glyph in glyphs {
            box = box.union(glyph.box)
            baselines.append(glyph.origin.y)
            guard !glyph.isSpace else { continue }
            nonSpace += 1
            if glyph.isLetter { letters += 1 }
            switch glyph.math {
            case .strong: strong += 1
            case .weak: weak += 1
            case .none: break
            }
        }
        return LayoutLine(glyphs: glyphs,
                          baseline: median(baselines),
                          fontSize: size,
                          bounds: box,
                          text: text(of: glyphs[0...], fontSize: size),
                          style: dominantStyle(glyphs),
                          strongMath: strong,
                          weakMath: weak,
                          nonSpace: nonSpace,
                          letters: letters,
                          cells: cellCount(glyphs, fontSize: size),
                          lineClass: .text,
                          hint: nil)
    }

    /// Builds the line text, inserting spaces from gaps when the PDF has no space
    /// glyphs of its own.
    static func text(of slice: ArraySlice<LayoutGlyph>, fontSize: CGFloat,
                     leadingSpace: Bool = false) -> String {
        var out = ""
        var pendingSpace = leadingSpace
        var started = false
        var rightEdge: CGFloat?
        for glyph in slice {
            if glyph.isSpace {
                pendingSpace = true
                rightEdge = max(rightEdge ?? glyph.box.maxX, glyph.box.maxX)
                continue
            }
            if glyph.unicode.isEmpty && glyph.box.width == 0 { continue }
            if let edge = rightEdge, glyph.box.minX - edge > 0.15 * fontSize {
                pendingSpace = true
            }
            if pendingSpace && (started || leadingSpace) { out += " " }
            out += glyph.unicode
            started = true
            pendingSpace = false
            rightEdge = max(rightEdge ?? glyph.box.minX, glyph.box.maxX)
        }
        return out
    }

    private static func cellCount(_ glyphs: [LayoutGlyph], fontSize: CGFloat) -> Int {
        var cells = 0
        var rightEdge: CGFloat?
        for glyph in glyphs where !glyph.isSpace {
            if let edge = rightEdge, glyph.box.minX - edge > 1.5 * fontSize { cells += 1 }
            rightEdge = max(rightEdge ?? glyph.box.minX, glyph.box.maxX)
        }
        return cells + 1
    }

    /// The most common glyph size, rounded so that a page set in one size reports
    /// one size even when the interpreter measures it slightly differently.
    /// `excludingMath` reports the size of the prose, which is what a paragraph
    /// wants: a formula inside it must not decide the size.
    static func dominantFontSize(_ glyphs: [LayoutGlyph], excludingMath: Bool = false) -> CGFloat {
        guard !glyphs.isEmpty else { return 0 }
        var counts: [CGFloat: Int] = [:]
        for glyph in glyphs where !glyph.isSpace && !(excludingMath && glyph.math == .strong) {
            counts[(glyph.fontSize * 2).rounded() / 2, default: 0] += 1
        }
        if counts.isEmpty {
            for glyph in glyphs where !glyph.isSpace {
                counts[(glyph.fontSize * 2).rounded() / 2, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return glyphs[0].fontSize }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }!.key
    }

    /// The size most lines are set in, which is the body size of the page.
    static func dominantFontSize(_ lines: [LayoutLine]) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var counts: [CGFloat: Int] = [:]
        for line in lines where line.nonSpace > 0 {
            counts[(line.fontSize * 2).rounded() / 2, default: 0] += 1
        }
        guard !counts.isEmpty else { return lines[0].fontSize }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }!.key
    }

    /// The size the running text is set in. Every character counts, so a page
    /// with a dense figure (many short labels in a small size) or a big table
    /// still reports the size of its prose. Lines inside figures and tables are
    /// left out when any line remains.
    static func bodyFontSize(_ lines: [LayoutLine], outside regions: [CGRect]) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let prose = lines.filter { !PDFLayoutTables.contains(regions, line: $0) }
        var counts: [CGFloat: Int] = [:]
        for line in prose.isEmpty ? lines : prose where line.nonSpace > 0 {
            counts[(line.fontSize * 2).rounded() / 2, default: 0] += line.nonSpace
        }
        guard !counts.isEmpty else { return lines[0].fontSize }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }!.key
    }

    static func dominantStyle(_ glyphs: [LayoutGlyph]) -> PDFFontStyle {
        var counts: [(style: PDFFontStyle, count: Int)] = []
        func add(_ style: PDFFontStyle) {
            if let i = counts.firstIndex(where: { $0.style == style }) {
                counts[i].count += 1
            } else {
                counts.append((style: style, count: 1))
            }
        }
        for glyph in glyphs where !glyph.isSpace && glyph.math != .strong { add(glyph.style) }
        if counts.isEmpty {
            for glyph in glyphs where !glyph.isSpace { add(glyph.style) }
        }
        return counts.max { $0.count < $1.count }?.style
            ?? PDFFontStyle(isSerif: false, isBold: false, isItalic: false, isMath: false, isMonospace: false)
    }

    static func mathStrength(of scalar: Unicode.Scalar, style: PDFFontStyle) -> LayoutMathStrength {
        if style.isMath { return .strong }
        switch scalar.value {
        case 0x2190...0x21FF, 0x2200...0x22FF, 0x27C0...0x27FF, 0x2900...0x297F,
             0x2A00...0x2AFF, 0x2B00...0x2BFF, 0x1D400...0x1D7FF:
            return .strong
        case 0x0370...0x03FF:
            // Greek letters are only mathematics in an italic or math font.
            return style.isItalic ? .strong : .none
        default:
            break
        }
        switch scalar {
        case "=", "±", "×", "÷":
            return .strong
        case "+", "-", "<", ">", "|", "/", "~", "*", "·", "°", "′", "″", "(", ")", "[", "]", ",":
            return .weak
        default:
            return .none
        }
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func percentile(_ values: [CGFloat], _ fraction: Double) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))
        return sorted[index]
    }
}
