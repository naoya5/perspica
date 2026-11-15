import CoreGraphics
import Foundation

/// Turns the interpreted page into paragraphs in reading order.
///
/// The analyzer is deliberately free of PDF syntax: it works on glyph boxes and
/// painted graphics only, so the same code serves the real interpreter and the
/// PDFKit approximation used by the tests.
public enum PDFLayoutAnalyzer {
    /// - glyphs and graphics: the interpreted page (see PDFTextModel.swift).
    /// - pageBox: the page's media box.
    /// - hints: optional paragraph boxes in page space from an OCR layout pass (Vision). Use them
    ///   only as hints for paragraph breaks and figure regions; the analyzer must work without them.
    public static func paragraphs(glyphs: [PDFGlyph], graphics: [PDFGraphic], pageBox: CGRect,
                                  hints: [CGRect] = []) -> [PDFParagraph] {
        let prepared = PDFLayoutGlyphs.prepare(glyphs)
        guard !prepared.isEmpty else { return [] }
        var lines = PDFLayoutGlyphs.lines(from: prepared)
        guard !lines.isEmpty else { return [] }
        let box = resolvedPageBox(lines: lines, given: pageBox)
        let figures = PDFLayoutFigures.regions(graphics: graphics, pageBox: box)
        let rules = PDFLayoutFigures.rules(graphics: graphics)
        let tables = PDFLayoutTables.regions(lines: lines, graphics: graphics, pageBox: box)
        let gutter = PDFLayoutColumns.gutter(lines: lines, tables: tables, figures: figures)
        var runs = PDFLayoutColumns.readingOrder(lines: lines, gutter: gutter)
        let bodySize = PDFLayoutGlyphs.bodyFontSize(lines, outside: figures + tables)
        PDFLayoutRoles.classify(&lines, runs: runs, pageBox: box, figures: figures, tables: tables,
                                hints: hints, bodySize: bodySize)

        // A display formula is a vertical stack of lines. Find the stacks before the
        // small pieces of an inline fraction are folded into the prose around them,
        // so that a stacked script of a formula is not mistaken for a fragment.
        var stacks: [Int: [Int]] = [:]
        var stacked: Set<Int> = []
        for run in runs {
            let metrics = PDFLayoutColumns.metrics(for: run, lines: lines)
            for stack in formulaStacks(run: run, lines: lines, metrics: metrics) {
                stacks[stack[0]] = stack
                stacked.formUnion(stack)
            }
        }
        // A row of scripts that spans several formula chunks has to be split
        // before the whole-row attachment runs, or one chunk would swallow it.
        let scripts = attachScriptRows(&lines, excluding: stacked)
        let absorbed = attachFragments(&lines, excluding: stacked.union(scripts))
        let removed = absorbed.union(scripts)
        runs = runs.map { $0.filter { !removed.contains($0) } }.filter { !$0.isEmpty }

        var planned: [(group: LineGroup, metrics: PDFLayoutColumns.Metrics)] = []
        for run in runs {
            let metrics = PDFLayoutColumns.metrics(for: run, lines: lines)
            for (position, group) in grouped(run: run, lines: lines, metrics: metrics,
                                             stacks: stacks).enumerated() {
                // Only the first group of a run can continue the run before it.
                if position == 0, let last = planned.last,
                   continuesAcrossRuns(last.group, group, lines: lines, metrics: last.metrics) {
                    planned[planned.count - 1].group.lines += group.lines
                } else {
                    planned.append((group, metrics))
                }
            }
        }
        return planned.map {
            paragraph(group: $0.group, lines: lines, bodySize: bodySize, pageBox: box, rules: rules,
                      graphics: graphics)
        }
    }

    /// Falls back to the glyph extent when the caller has no media box, so that
    /// margin and centring rules still have a frame to work with.
    private static func resolvedPageBox(lines: [LayoutLine], given: CGRect) -> CGRect {
        guard given.width > 0, given.height > 0 else {
            let bounds = lines.reduce(CGRect.null) { $0.union($1.bounds) }
            return bounds.isNull ? .zero : bounds
        }
        return given
    }

    // MARK: - Paragraphs

    /// One paragraph under construction: either consecutive lines of prose or the
    /// lines of a display formula, which are stacked and must stay together.
    private struct LineGroup {
        var lines: [Int]
        var isFormulaStack: Bool
    }

    private static func grouped(run: [Int], lines: [LayoutLine], metrics: PDFLayoutColumns.Metrics,
                                stacks: [Int: [Int]]) -> [LineGroup] {
        var groups: [LineGroup] = []
        var current: [Int] = []
        var position = 0
        while position < run.count {
            let index = run[position]
            if let stack = stacks[index] {
                if !current.isEmpty {
                    groups.append(LineGroup(lines: current, isFormulaStack: false))
                    current = []
                }
                groups.append(LineGroup(lines: stack, isFormulaStack: true))
                position += stack.count
                continue
            }
            if let previous = current.last, breaks(lines[previous], lines[index], metrics: metrics) {
                groups.append(LineGroup(lines: current, isFormulaStack: false))
                current = []
            }
            current.append(index)
            position += 1
        }
        if !current.isEmpty { groups.append(LineGroup(lines: current, isFormulaStack: false)) }
        return groups
    }

    private static func breaks(_ previous: LayoutLine, _ current: LayoutLine,
                               metrics: PDFLayoutColumns.Metrics) -> Bool {
        // A formula chunk beside the text line it belongs to stays on that line.
        if current.continues { return false }
        if previous.lineClass != current.lineClass { return true }
        if previous.hint != current.hint { return true }
        let gap = previous.baseline - current.baseline
        if gap < 0 { return true }
        if gap > 1.45 * metrics.leading { return true }
        let size = max(previous.fontSize, current.fontSize)
        if abs(previous.fontSize - current.fontSize) > 0.12 * size { return true }
        if !PDFLayoutRoles.continuesStyle(previous, into: current) { return true }
        // Two pieces on one baseline with a wide gap are side by side, not one
        // paragraph: figure labels, table cells and separate formula chunks.
        if gap <= 0.5 * size, current.bounds.minX - previous.bounds.maxX > 2 * size,
           previous.lineClass != .formula || current.lineClass != .formula {
            return true
        }
        // Lines of one paragraph share part of their width; two labels side by side
        // in a figure do not. A formula chunk that ends the line above is narrow,
        // so the next line is compared with the text, not with the chunk.
        if !previous.continues, current.lineClass != .formula,
           current.bounds.minX > previous.bounds.maxX || current.bounds.maxX < previous.bounds.minX {
            return true
        }
        // A first-line indent starts a paragraph, but only in running text: a
        // centred heading or caption has a different left edge on every line.
        if previous.lineClass == .text, current.lineClass == .text {
            let indent = current.bounds.minX - metrics.left
            let previousIndent = previous.bounds.minX - metrics.left
            if indent > 0.9 * current.fontSize, previousIndent <= 0.5 * previous.fontSize {
                return true
            }
        }
        let typicalWidth = max(metrics.textRight - metrics.left, 1)
        let previousShort = metrics.textRight - previous.bounds.maxX > 1.5 * previous.fontSize
            && previous.bounds.width < 0.75 * typicalWidth
        if previousShort, current.bounds.width > 0.5 * typicalWidth { return true }
        if PDFLayoutRoles.startsWithListMarker(current.text) { return true }
        return false
    }

    /// A short last line stays with the paragraph above it even when the reading
    /// order puts the two in different runs. A table in the middle of a page can
    /// make the column finder see a gutter, and then the full-width lines above
    /// and below the table form one run while the short last lines form another.
    /// The gap, the font and the left edge tell a continuation from a new block.
    private static func continuesAcrossRuns(_ previous: LineGroup, _ next: LineGroup,
                                            lines: [LayoutLine],
                                            metrics: PDFLayoutColumns.Metrics) -> Bool {
        guard !previous.isFormulaStack, !next.isFormulaStack,
              let above = previous.lines.last.map({ lines[$0] }),
              let below = next.lines.first.map({ lines[$0] }) else { return false }
        // Only a short line continues a paragraph; a new block starts with a full line.
        guard PDFLayoutRoles.isShort(below, metrics: metrics) else { return false }
        let gap = above.baseline - below.baseline
        guard gap > 0, abs(gap - metrics.leading) <= 0.15 * metrics.leading else { return false }
        let size = max(above.fontSize, below.fontSize)
        guard abs(above.fontSize - below.fontSize) <= 0.12 * size,
              PDFLayoutRoles.continuesStyle(above, into: below) else { return false }
        // A caption or a heading that wraps keeps its last line in the same block.
        switch (above.lineClass, below.lineClass) {
        case (.text, .text), (.caption, .text), (.heading, .text): break
        default: return false
        }
        // Both lines start at the same edge; a new column starts at another edge.
        return abs(above.bounds.minX - below.bounds.minX) <= 0.5 * below.fontSize
    }

    private static func paragraph(group: LineGroup, lines: [LayoutLine], bodySize: CGFloat,
                                  pageBox: CGRect, rules: [CGRect],
                                  graphics: [PDFGraphic]) -> PDFParagraph {
        let members = group.lines.map { lines[$0] }
        let role = group.isFormulaStack
            ? PDFParagraph.Role.formula
            : PDFLayoutRoles.role(of: members, bodySize: bodySize, pageBox: pageBox, rules: rules)
        let text = members.map(\.text).joined(separator: " ")
        let translate = role != .pageFurniture && role != .formula && role != .other
            && text.contains(where: \.isLetter)
        let glyphs = members.flatMap(\.glyphs) + members.flatMap { $0.fragments.flatMap { $0 } }
        let bounds = members.reduce(CGRect.null) { $0.union($1.bounds) }
        return PDFParagraph(role: role,
                            bounds: bounds,
                            lineBounds: members.map(\.bounds),
                            segments: segments(members, role: role, graphics: graphics),
                            glyphIndices: glyphs.map(\.index),
                            fontSize: PDFLayoutGlyphs.dominantFontSize(members.flatMap(\.glyphs),
                                                                      excludingMath: true),
                            style: PDFLayoutGlyphs.dominantStyle(members.flatMap(\.glyphs)),
                            translate: translate)
    }

    // MARK: - Segments

    private static func segments(_ lines: [LayoutLine], role: PDFParagraph.Role,
                                 graphics: [PDFGraphic]) -> [PDFTextSegment] {
        if role == .formula {
            let text = lines.map(\.text).joined(separator: " ")
            let bounds = lines.reduce(CGRect.null) { $0.union($1.bounds) }
            // The line carrying most of the formula gives the block its baseline,
            // so that the descent of a stacked equation stays meaningful.
            let baseline = lines.max { $0.nonSpace < $1.nonSpace }?.baseline ?? 0
            return [.formula(text: text, bounds: bounds, baseline: baseline)]
        }
        var out: [PDFTextSegment] = []
        for line in lines {
            append(lineSegments(line, graphics: graphics), to: &out)
        }
        return out
    }

    /// One inline formula under construction: the glyphs on its own line, the box
    /// they cover, and the text of the small pieces stacked above or below it.
    private struct InlineFormula {
        var sortX: CGFloat
        var box: CGRect
        var glyphs: [LayoutGlyph]
        /// The math run the formula came from, when it is one run of the line.
        var run: Range<Int>?
        /// A fraction's numerator, set above the formula.
        var numerator = ""
        /// A word space separated the numerator from the text before it.
        var numeratorSpace = false
        /// A fraction's denominator, set below the formula.
        var denominator = ""

        /// The formula as running text. A fraction reads "1/√dk" so that the
        /// fallback text still says what the formula is.
        var text: String {
            var out = glyphs.map(\.unicode).joined()
            if !numerator.isEmpty { out = numerator + "/" + out }
            if !denominator.isEmpty { out += "/" + denominator }
            return out
        }
    }

    /// Splits one line into text and the inline formulas it contains, including
    /// the small stacked pieces folded into those formulas.
    private static func lineSegments(_ line: LayoutLine, graphics: [PDFGraphic]) -> [PDFTextSegment] {
        let runs = mathRuns(in: line)
        // One formula per math run, plus one for every fragment that no run
        // covers: a footnote mark after a word is a formula of its own.
        var formulas: [InlineFormula] = runs.map { run in
            let glyphs = Array(line.glyphs[run])
            let box = glyphs.reduce(CGRect.null) { $0.union($1.box) }
            return InlineFormula(sortX: box.minX, box: box, glyphs: glyphs, run: run)
        }
        let tolerance = 0.25 * line.fontSize
        for fragment in line.fragments {
            let box = fragment.reduce(CGRect.null) { $0.union($1.box) }
            // A fragment joins the formula it overlaps as a whole, so that no
            // glyph of a stacked piece is left out of its segment.
            if let index = formulas.firstIndex(where: {
                box.minX <= $0.box.maxX + tolerance && box.maxX >= $0.box.minX - tolerance
            }) {
                formulas[index].glyphs += fragment
                formulas[index].box = formulas[index].box.union(box)
            } else {
                formulas.append(InlineFormula(sortX: box.minX, box: box, glyphs: fragment, run: nil))
            }
        }
        let stacked = absorbStackedGlyphs(&formulas, line: line, runs: runs)
        coverRules(&formulas, graphics: graphics, tolerance: tolerance)
        formulas.sort { $0.sortX < $1.sortX }
        // Walk the line left to right: the text between two formulas, then the
        // formula itself, so that a mark after a word stays after that word.
        var pieces: [(minX: CGFloat, segment: PDFTextSegment)] = []
        var cursor = 0
        func appendText(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let glyphs = line.glyphs[range].filter { !stacked.contains($0.index) }
            guard let first = glyphs.first else { return }
            let text = PDFLayoutGlyphs.text(of: glyphs[...], fontSize: line.fontSize)
            if !text.isEmpty { pieces.append((first.box.minX, .text(text))) }
        }
        for formula in formulas {
            let split = formula.run?.lowerBound
                ?? (cursor..<line.glyphs.count).first { line.glyphs[$0].box.minX >= formula.sortX }
                ?? line.glyphs.count
            if cursor < split { appendText(cursor..<split) }
            // The numerator used to be text, so the word space in front of it now
            // has to be drawn by the text piece before the formula.
            if formula.numeratorSpace, case .text(let tail)? = pieces.last?.segment,
               !tail.hasSuffix(" ") {
                pieces[pieces.count - 1].segment = .text(tail + " ")
            }
            pieces.append((formula.sortX,
                           .formula(text: formula.text, bounds: formula.box, baseline: line.baseline)))
            cursor = max(cursor, formula.run?.upperBound ?? split)
        }
        if cursor < line.glyphs.count { appendText(cursor..<line.glyphs.count) }
        var out: [PDFTextSegment] = []
        for piece in pieces {
            switch piece.segment {
            case .formula(let text, let bounds, _):
                // Runs that touch are one formula: the gaps between the glyphs of
                // "W_i ∈ R" are kerning, not a break in the mathematics.
                if case .formula(let last, let lastBounds, let lastBaseline) = out.last,
                   bounds.minX - lastBounds.maxX <= 0.6 * line.fontSize {
                    out[out.count - 1] = .formula(text: last + text, bounds: lastBounds.union(bounds),
                                                  baseline: lastBaseline)
                } else {
                    out.append(piece.segment)
                }
            case .text(var value):
                // Pieces are placed left to right, so a text piece that follows a
                // formula needs the space the PDF does not draw. Punctuation that
                // closes the formula takes no space.
                if !out.isEmpty, !value.hasPrefix(" "),
                   value.first.map({ !",.;:?!)]}".contains($0) }) ?? true {
                    value = " " + value
                }
                out.append(.text(value))
            }
        }
        return out
    }

    /// Folds a small glyph set directly above or below an inline formula into that
    /// formula. The numerator of an inline fraction is drawn as a glyph of the text
    /// line, outside the formula's math run, so without this it is sent to the
    /// model as text and also drawn again inside the formula.
    private static func absorbStackedGlyphs(_ formulas: inout [InlineFormula], line: LayoutLine,
                                            runs: [Range<Int>]) -> Set<Int> {
        guard !formulas.isEmpty else { return [] }
        var inRun: Set<Int> = []
        for run in runs { inRun.formUnion(run) }
        var absorbed: Set<Int> = []
        for (position, glyph) in line.glyphs.enumerated() where !inRun.contains(position) {
            guard !glyph.isSpace, glyph.fontSize <= 0.9 * line.fontSize else { continue }
            let offset = glyph.origin.y - line.baseline
            // On the baseline is ordinary text of the line; more than a line away
            // is a line of its own, which the fragment pass handles.
            guard abs(offset) >= 0.2 * line.fontSize, abs(offset) <= line.fontSize else { continue }
            guard let target = formulas.firstIndex(where: { formula in
                min(glyph.box.maxX, formula.box.maxX) - max(glyph.box.minX, formula.box.minX) > 0
            }) else { continue }
            if offset > 0 {
                // The numerator was text before it became part of the formula, so
                // the word space in front of it has to come along.
                if formulas[target].numerator.isEmpty {
                    formulas[target].numeratorSpace = wordSpaceBefore(position, in: line)
                }
                formulas[target].numerator += glyph.unicode
            } else {
                formulas[target].denominator += glyph.unicode
            }
            formulas[target].box = formulas[target].box.union(glyph.box)
            absorbed.insert(glyph.index)
        }
        return absorbed
    }

    /// True when a word space separates the glyph at `position` from the glyph
    /// before it, either as a space glyph or as a gap the PDF does not draw.
    private static func wordSpaceBefore(_ position: Int, in line: LayoutLine) -> Bool {
        guard position > 0 else { return false }
        let previous = line.glyphs[position - 1]
        if previous.isSpace { return true }
        return line.glyphs[position].box.minX - previous.box.maxX > 0.15 * line.fontSize
    }

    /// Grows a formula box over the rules drawn inside it: the fraction bar between
    /// its numerator and denominator, and a radical's overbar. They are paths, not
    /// glyphs, so the box has to take them in explicitly: the translator draws the
    /// formula clipped to this box and removes the paths that fall inside it.
    private static func coverRules(_ formulas: inout [InlineFormula], graphics: [PDFGraphic],
                                   tolerance: CGFloat) {
        for index in formulas.indices {
            for graphic in graphics where graphic.kind == .path {
                let rule = graphic.bounds
                guard rule.width > 0 || rule.height > 0 else { continue }
                guard rule.minX >= formulas[index].box.minX - tolerance,
                      rule.maxX <= formulas[index].box.maxX + tolerance,
                      rule.minY >= formulas[index].box.minY - tolerance,
                      rule.maxY <= formulas[index].box.maxY + tolerance else { continue }
                formulas[index].box = formulas[index].box.union(rule)
            }
        }
    }

    /// Maximal runs of mathematics inside a text line. A run starts at a strong
    /// symbol and continues over attached math, italics and smaller glyphs, which
    /// is how subscripts and the letters of a formula stay together.
    private static func mathRuns(in line: LayoutLine) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        var rightEdge: CGFloat?
        for (i, glyph) in line.glyphs.enumerated() {
            let attached = rightEdge.map { glyph.box.minX - $0 <= 0.15 * line.fontSize } ?? false
            let continues = glyph.math != .none
                || (attached && (glyph.style.isItalic || glyph.fontSize < line.fontSize * 0.95))
            if let begin = start {
                if !(continues && attached) {
                    runs.append(begin..<i)
                    start = nil
                }
            }
            if start == nil, glyph.math == .strong { start = i }
            rightEdge = max(rightEdge ?? glyph.box.minX, glyph.box.maxX)
        }
        if let begin = start { runs.append(begin..<line.glyphs.count) }
        return runs
    }

    private static func append(_ line: [PDFTextSegment], to out: inout [PDFTextSegment]) {
        guard !line.isEmpty else { return }
        guard let last = out.last, let first = line.first else {
            out = line
            return
        }
        switch (last, first) {
        case (.text(var tail), .text(var head)):
            if tail.hasSuffix("-"), tail.dropLast().last?.isLetter == true, head.first?.isLowercase == true {
                tail = String(tail.dropLast())
            } else if !tail.hasSuffix(" "), !head.hasPrefix(" ") {
                head = " " + head
            }
            out[out.count - 1] = .text(tail)
            out.append(.text(head))
        case (.text(var tail), .formula):
            if !tail.hasSuffix(" ") { tail += " " }
            out[out.count - 1] = .text(tail)
            out.append(first)
        case (.formula, .text(var head)):
            // No space before the punctuation that closes a formula: "{..}, {..}".
            if !head.hasPrefix(" "), head.first.map({ !",.;:?!)]}".contains($0) }) ?? true {
                head = " " + head
            }
            out.append(.text(head))
        case (.formula, .formula):
            out.append(first)
        }
        out.append(contentsOf: line.dropFirst())
    }

    // MARK: - Display formulas

    /// Consecutive lines that form one display formula: stacked lines that overlap
    /// horizontally, sit within about one line height of each other and read as
    /// mathematics. The top line has to be mathematics, so prose above a formula
    /// stays a paragraph of its own.
    private static func formulaStacks(run: [Int], lines: [LayoutLine],
                                      metrics: PDFLayoutColumns.Metrics) -> [[Int]] {
        var stacks: [[Int]] = []
        var position = 0
        while position < run.count {
            var end = position + 1
            while end < run.count, stacksTogether(lines[run[end - 1]], lines[run[end]]) {
                end += 1
            }
            var start = position
            var found = false
            while end - start >= 2 {
                let members = Array(run[start..<end])
                if readsAsMath(members.map { lines[$0] }, metrics: metrics) {
                    stacks.append(members)
                    position = end
                    found = true
                    break
                }
                start += 1
            }
            if !found { position += 1 }
        }
        return stacks
    }

    private static func stacksTogether(_ above: LayoutLine, _ below: LayoutLine) -> Bool {
        let gap = above.baseline - below.baseline
        guard gap >= 0, gap <= 1.4 * max(above.fontSize, below.fontSize) else { return false }
        let overlap = min(above.bounds.maxX, below.bounds.maxX)
            - max(above.bounds.minX, below.bounds.minX)
        return overlap > 0
    }

    private static func readsAsMath(_ group: [LayoutLine], metrics: PDFLayoutColumns.Metrics) -> Bool {
        guard let first = group.first, isMathLine(first) else { return false }
        let mathLines = group.filter(isMathLine).count
        if mathLines == group.count { return true }
        let total = group.reduce(0) { $0 + $1.nonSpace }
        let math = group.reduce(0) { $0 + $1.strongMath + $1.weakMath }
        if total > 0, Double(math) >= 0.6 * Double(total) { return true }
        if mathLines * 2 > group.count, isCenteredBlock(group, metrics: metrics) { return true }
        return group.last.map { endsWithEquationNumber($0, metrics: metrics) } ?? false
    }

    /// A line that is mathematics: a formula line, mostly math glyphs, or a line
    /// whose prose is no more than a few function names around the formula.
    private static func isMathLine(_ line: LayoutLine) -> Bool {
        if line.lineClass == .formula { return true }
        guard line.strongMath > 0 else { return false }
        let ratio = Double(line.strongMath + line.weakMath) / Double(max(line.nonSpace, 1))
        if ratio >= 0.6 { return true }
        let words = proseWords(in: line)
        guard !words.isEmpty, words.count <= 4 else { return false }
        return words.allSatisfy { word in
            mathFunctionWords.contains(word.lowercased()) || word.allSatisfy(\.isNumber)
        }
    }

    /// Function names that may surround the mathematics of a display formula.
    private static let mathFunctionWords: Set<String> = [
        "softmax", "attention", "max", "exp", "log", "concat", "head", "multihead",
        "ffn", "pe", "sin", "cos", "layernorm", "sublayer",
    ]

    /// The words of a line that are set in its text font, outside its formula runs.
    private static func proseWords(in line: LayoutLine) -> [String] {
        var words: [String] = []
        var cursor = 0
        func collect(_ slice: ArraySlice<LayoutGlyph>) {
            var word = ""
            for glyph in slice {
                if glyph.isSpace || glyph.math != .none {
                    if !word.isEmpty { words.append(word) }
                    word = ""
                } else {
                    word += glyph.unicode
                }
            }
            if !word.isEmpty { words.append(word) }
        }
        for run in mathRuns(in: line) {
            if cursor < run.lowerBound { collect(line.glyphs[cursor..<run.lowerBound]) }
            cursor = run.upperBound
        }
        if cursor < line.glyphs.count { collect(line.glyphs[cursor...]) }
        return words
    }

    private static func isCenteredBlock(_ group: [LayoutLine], metrics: PDFLayoutColumns.Metrics) -> Bool {
        let bounds = group.reduce(CGRect.null) { $0.union($1.bounds) }
        let columnWidth = max(metrics.right - metrics.left, 1)
        guard bounds.width > 0, bounds.width < 0.8 * columnWidth else { return false }
        return abs(bounds.midX - (metrics.left + metrics.right) / 2) <= 0.06 * columnWidth
    }

    private static func endsWithEquationNumber(_ line: LayoutLine,
                                               metrics: PDFLayoutColumns.Metrics) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return false }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard (1...2).contains(inner.count), inner.allSatisfy({ $0.isNumber || $0.isLetter }) else {
            return false
        }
        let columnWidth = max(metrics.right - metrics.left, 1)
        return line.bounds.maxX >= metrics.right - 0.1 * columnWidth
    }

    // MARK: - Inline fragments

    /// Folds small stacked pieces of mathematics (the denominator of an inline
    /// fraction, a stacked script) into the prose line they belong to, so that they
    /// travel with the translated text instead of becoming a paragraph of their own.
    private static func attachFragments(_ lines: inout [LayoutLine],
                                        excluding reserved: Set<Int>) -> Set<Int> {
        var absorbed: Set<Int> = []
        let hosts = lines.indices.filter { canHostFragment(lines[$0]) }
        for index in lines.indices where !reserved.contains(index) {
            let fragment = lines[index]
            guard isFragment(fragment) else { continue }
            var best: (index: Int, distance: CGFloat)?
            for host in hosts where host != index {
                let line = lines[host]
                guard fragment.fontSize < 0.9 * line.fontSize else { continue }
                guard fragment.bounds.intersects(line.bounds.insetBy(dx: 0, dy: -0.6 * line.fontSize))
                else { continue }
                // A fragment belongs to a formula of this line, so it must not
                // reach far beyond the line: a wide stacked row of superscripts
                // that spans several lines is not an inline piece.
                let span = line.bounds.insetBy(dx: -0.5 * line.fontSize, dy: 0)
                guard fragment.bounds.intersection(span).width >= 0.5 * fragment.bounds.width
                else { continue }
                // The fragment either extends a formula of the line or follows a
                // word of it: a footnote mark inside body text. A mark set before
                // the first word of a footnote line has no word before it and
                // stays a paragraph of its own.
                guard overlapsFormulaRun(fragment, in: line) || followsWord(fragment, in: line)
                else { continue }
                let distance = abs(fragment.baseline - line.baseline)
                if best == nil || distance < best!.distance { best = (host, distance) }
            }
            guard let host = best?.index else { continue }
            lines[host].fragments.append(fragment.glyphs)
            lines[host].bounds = lines[host].bounds.union(fragment.bounds)
            absorbed.insert(index)
        }
        return absorbed
    }

    /// Folds a row of small glyphs that spans several formula chunks of a line
    /// into those chunks. "W_i^Q ∈ R^{d_model×d_k}, W_i^K ∈ R^{...}" sets the
    /// exponents in one 5 pt row over three chunks of the line, so the row has to
    /// be split at the chunks instead of becoming a paragraph of its own.
    private static func attachScriptRows(_ lines: inout [LayoutLine],
                                         excluding reserved: Set<Int>) -> Set<Int> {
        var absorbed: Set<Int> = []
        for index in lines.indices where !reserved.contains(index) {
            let row = lines[index]
            guard row.nonSpace > 0, row.strongMath > 0 else { continue }
            let chunks = scriptChunks(of: row, in: lines, excluding: index)
            guard chunks.count >= 2 else { continue }
            let tolerance = 0.5 * row.fontSize
            var pieces = [[LayoutGlyph]](repeating: [], count: chunks.count)
            for glyph in row.glyphs {
                var target = 0
                for (i, chunk) in chunks.enumerated() where chunk.box.minX <= glyph.box.minX + tolerance {
                    target = i
                }
                pieces[target].append(glyph)
            }
            // A row that lands in one chunk is not a row of scripts.
            guard pieces.filter({ !$0.isEmpty }).count >= 2 else { continue }
            for (i, piece) in pieces.enumerated() where !piece.isEmpty {
                let box = piece.reduce(CGRect.null) { $0.union($1.box) }
                lines[chunks[i].line].fragments.append(piece)
                lines[chunks[i].line].bounds = lines[chunks[i].line].bounds.union(box)
            }
            absorbed.insert(index)
        }
        return absorbed
    }

    /// The formula chunks a row of scripts can belong to: the math runs of the
    /// text lines just above or below it that it reaches horizontally.
    private static func scriptChunks(of row: LayoutLine, in lines: [LayoutLine],
                                     excluding index: Int) -> [(line: Int, box: CGRect)] {
        let tolerance = 0.25 * row.fontSize
        var chunks: [(line: Int, box: CGRect)] = []
        for host in lines.indices where host != index {
            let line = lines[host]
            guard row.fontSize <= 0.7 * line.fontSize else { continue }
            guard abs(row.baseline - line.baseline) <= 0.8 * line.fontSize else { continue }
            guard row.bounds.intersects(line.bounds) else { continue }
            for run in mathRuns(in: line) {
                let box = line.glyphs[run].reduce(CGRect.null) { $0.union($1.box) }
                guard row.bounds.minX <= box.maxX + tolerance,
                      row.bounds.maxX >= box.minX - tolerance else { continue }
                chunks.append((host, box))
            }
        }
        return chunks.sorted { $0.box.minX < $1.box.minX }
    }

    private static func canHostFragment(_ line: LayoutLine) -> Bool {
        line.letters > 0 && line.nonSpace > 0 && !isMathLine(line) && !isFragment(line)
    }

    private static func isFragment(_ line: LayoutLine) -> Bool {
        guard line.nonSpace > 0 else { return false }
        if line.strongMath > 0 {
            let ratio = Double(line.strongMath + line.weakMath) / Double(line.nonSpace)
            if ratio >= 0.5 { return true }
        }
        // A footnote mark: one or two digits or symbols on their own.
        return line.nonSpace <= 2 && line.letters == 0
    }

    /// The fragment sits after a word of the line, not in front of it.
    private static func followsWord(_ fragment: LayoutLine, in line: LayoutLine) -> Bool {
        let tolerance = 0.5 * line.fontSize
        return line.glyphs.contains { !$0.isSpace && $0.box.maxX <= fragment.bounds.minX + tolerance }
    }

    private static func overlapsFormulaRun(_ fragment: LayoutLine, in line: LayoutLine) -> Bool {
        let tolerance = 0.25 * line.fontSize
        for run in mathRuns(in: line) {
            let box = line.glyphs[run].reduce(CGRect.null) { $0.union($1.box) }
            if fragment.bounds.minX <= box.maxX + tolerance,
               fragment.bounds.maxX >= box.minX - tolerance {
                return true
            }
        }
        return false
    }
}
