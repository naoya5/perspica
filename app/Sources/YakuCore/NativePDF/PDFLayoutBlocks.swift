import CoreGraphics
import Foundation

/// Finds columns and puts lines in reading order.
enum PDFLayoutColumns {
    /// The gutter between two columns: a vertical band that no body line crosses
    /// over most of the page height.
    ///
    /// Two signals are tried in turn. The shared-edge signal is the reliable one
    /// and is what finds the gutter of a two-column paper. The gap signal is the
    /// older, looser one: it keeps the pages it already handled unchanged, such
    /// as a table whose cells happen to line up in two blocks.
    static func gutter(lines: [LayoutLine], tables: [CGRect],
                       figures: [CGRect]) -> ClosedRange<CGFloat>? {
        sharedEdgeGutter(lines: lines, tables: tables, figures: figures) ?? gapGutter(lines: lines)
    }

    /// A gutter found from the two edges the columns share.
    ///
    /// Nearly every line of the left column ends at one x, and nearly every line
    /// of the right column starts at another. The gutter is the gap between them.
    /// Requiring both edges to be shared by several lines is what separates a real
    /// gutter from the labels and formula fragments that sit side by side on a
    /// single-column page: those share no edge, so they cannot invent a gutter.
    ///
    /// The lines that do cross the band are the full-width elements: the title,
    /// the author block, a wide figure or table and its caption. They may cross as
    /// long as they cover only a small part of the page height, which keeps a
    /// table that happens to have two columns of cells from splitting the page.
    private static func sharedEdgeGutter(lines: [LayoutLine], tables: [CGRect],
                                         figures: [CGRect]) -> ClosedRange<CGFloat>? {
        let candidates = lines.filter { $0.nonSpace > 0 && $0.bounds.width > 0 }
        guard candidates.count >= 6 else { return nil }
        guard let minX = candidates.map(\.bounds.minX).min(),
              let maxX = candidates.map(\.bounds.maxX).max() else { return nil }
        let contentWidth = maxX - minX
        guard contentWidth > 0 else { return nil }
        // Only body lines are obstacles, and only they decide the em. The text
        // inside a figure or a table is exempt from translation already, and a
        // figure's tiny labels must not shrink the em the gutter is measured in.
        let body = candidates.filter { line in
            let point = CGPoint(x: line.bounds.midX, y: line.bounds.midY)
            return !tables.contains { $0.contains(point) } && !figures.contains { $0.contains(point) }
        }
        let em = PDFLayoutGlyphs.dominantFontSize(body)
        guard em > 0 else { return nil }
        let tolerance = 0.25 * em
        // A gutter is a few ems wide. Narrower gaps are word spaces, wider ones
        // are the margins of the text area.
        let minBand = max(1.5 * em, 0.03 * contentWidth)
        let maxBand = 4 * em
        let textHeight = (candidates.map(\.bounds.maxY).max() ?? 0)
            - (candidates.map(\.bounds.minY).min() ?? 0)
        let leftEdges = sharedEdges(candidates.map(\.bounds.maxX), tolerance: tolerance)
        let rightEdges = sharedEdges(candidates.map(\.bounds.minX), tolerance: tolerance)

        var best: (band: ClosedRange<CGFloat>, support: Int)?
        for low in leftEdges {
            for high in rightEdges where high - low >= minBand && high - low <= maxBand {
                let center = (low + high) / 2
                guard center > minX + 0.3 * contentWidth,
                      center < minX + 0.7 * contentWidth else { continue }
                let left = candidates.filter { $0.bounds.maxX <= low + tolerance }
                let right = candidates.filter { $0.bounds.minX >= high - tolerance }
                guard left.count >= 3, right.count >= 3 else { continue }
                // A real gutter has lines on both sides at the same heights.
                let interleaved = left.filter { line in
                    right.contains { abs($0.baseline - line.baseline) <= 0.75 * em }
                }.count
                guard interleaved >= 2 else { continue }
                let crossing = body.filter {
                    $0.bounds.minX < high - tolerance && $0.bounds.maxX > low + tolerance
                }
                guard verticalExtent(of: crossing) <= 0.35 * textHeight else { continue }
                let support = left.filter { abs($0.bounds.maxX - low) <= tolerance }.count
                    + right.filter { abs($0.bounds.minX - high) <= tolerance }.count
                if best == nil || support > best!.support { best = (low...high, support) }
            }
        }
        return best?.band
    }

    /// A gutter found from the gap alone: a band that no narrow line crosses and
    /// that has several lines on either side at the same heights.
    private static func gapGutter(lines: [LayoutLine]) -> ClosedRange<CGFloat>? {
        let candidates = lines.filter { $0.nonSpace > 0 && $0.bounds.width > 0 }
        guard candidates.count >= 6 else { return nil }
        guard let minX = candidates.map(\.bounds.minX).min(),
              let maxX = candidates.map(\.bounds.maxX).max() else { return nil }
        let contentWidth = maxX - minX
        guard contentWidth > 0 else { return nil }
        let narrow = candidates.filter { $0.bounds.width < 0.6 * contentWidth }
        guard narrow.count >= 6 else { return nil }
        let em = PDFLayoutGlyphs.median(narrow.map(\.fontSize))
        let minBand = max(1.5 * em, 0.03 * contentWidth)

        var edges: Set<CGFloat> = []
        for line in narrow {
            edges.insert((line.bounds.minX * 2).rounded() / 2)
            edges.insert((line.bounds.maxX * 2).rounded() / 2)
        }
        let sorted = edges.sorted()
        var best: (band: ClosedRange<CGFloat>, width: CGFloat)?
        for i in 0..<max(sorted.count - 1, 0) {
            let low = sorted[i]
            let high = sorted[i + 1]
            let width = high - low
            guard width >= minBand else { continue }
            let center = (low + high) / 2
            guard center > minX + 0.3 * contentWidth, center < minX + 0.7 * contentWidth else { continue }
            let crossed = narrow.contains { $0.bounds.minX < high - 0.5 && $0.bounds.maxX > low + 0.5 }
            guard !crossed else { continue }
            let left = narrow.filter { $0.bounds.maxX <= low + 0.5 }
            let right = narrow.filter { $0.bounds.minX >= high - 0.5 }
            guard left.count >= 3, right.count >= 3 else { continue }
            let interleaved = left.filter { leftLine in
                right.contains { abs($0.baseline - leftLine.baseline) <= 0.75 * em }
            }.count
            guard interleaved >= 2 else { continue }
            guard Double(left.count + right.count) >= 0.6 * Double(narrow.count) else { continue }
            if best == nil || width > best!.width { best = (low...high, width) }
        }
        return best?.band
    }

    /// The x values that at least three lines share, one per cluster of nearby
    /// values. The value with the most support stands for its cluster, so that a
    /// stray line just beside the column edge does not move the band.
    private static func sharedEdges(_ values: [CGFloat], tolerance: CGFloat) -> [CGFloat] {
        let sorted = values.sorted()
        var out: [CGFloat] = []
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count, sorted[end] - sorted[end - 1] <= tolerance { end += 1 }
            var best: (value: CGFloat, support: Int)?
            for value in sorted[index..<end] {
                let support = sorted[index..<end].filter { abs($0 - value) <= tolerance }.count
                if best == nil || support > best!.support { best = (value, support) }
            }
            if let best, best.support >= 3 { out.append(best.value) }
            index = end
        }
        return out
    }

    /// How much of the page height a set of lines covers, counting overlaps once.
    private static func verticalExtent(of lines: [LayoutLine]) -> CGFloat {
        let intervals = lines.map { (low: $0.bounds.minY, high: $0.bounds.maxY) }
            .sorted { $0.low < $1.low }
        guard var current = intervals.first else { return 0 }
        var total: CGFloat = 0
        for interval in intervals.dropFirst() {
            if interval.low <= current.high {
                current.high = max(current.high, interval.high)
            } else {
                total += current.high - current.low
                current = interval
            }
        }
        return total + current.high - current.low
    }

    /// Line indices in reading order: full-width blocks where they sit
    /// vertically, and inside a two-column region the whole left column from top
    /// to bottom, then the right column. The columns of a region share their
    /// baselines, so a line by line walk would interleave them.
    static func readingOrder(lines: [LayoutLine], gutter: ClosedRange<CGFloat>?) -> [[Int]] {
        let order = lines.indices.sorted { lhs, rhs in
            if lines[lhs].baseline != lines[rhs].baseline { return lines[lhs].baseline > lines[rhs].baseline }
            return lines[lhs].bounds.minX < lines[rhs].bounds.minX
        }
        guard let band = gutter else { return [order] }
        let bandCenter = (band.lowerBound + band.upperBound) / 2

        var runs: [[Int]] = []
        var fullWidth: [Int] = []
        var left: [Int] = []
        var right: [Int] = []
        func flushColumns() {
            if !left.isEmpty { runs.append(left); left = [] }
            if !right.isEmpty { runs.append(right); right = [] }
        }
        func flushFullWidth() {
            if !fullWidth.isEmpty { runs.append(fullWidth); fullWidth = [] }
        }
        for index in order {
            let line = lines[index]
            if line.bounds.minX <= band.lowerBound && line.bounds.maxX >= band.upperBound {
                flushColumns()
                fullWidth.append(index)
            } else {
                flushFullWidth()
                if line.bounds.midX < bandCenter { left.append(index) } else { right.append(index) }
            }
        }
        flushColumns()
        flushFullWidth()
        return runs
    }

    struct Metrics: Sendable {
        /// Left edge of the column, taken from the most common line start.
        let left: CGFloat
        /// Right edge of the text area, from the widest line. Used for centring,
        /// where an equation number at the margin must count.
        let right: CGFloat
        /// Where lines usually end. A short line is short compared with this.
        let textRight: CGFloat
        /// The usual baseline distance between consecutive lines.
        let leading: CGFloat
    }

    static func metrics(for run: [Int], lines: [LayoutLine]) -> Metrics {
        guard !run.isEmpty else { return Metrics(left: 0, right: 0, textRight: 0, leading: 0) }
        let left = PDFLayoutGlyphs.median(run.map { lines[$0].bounds.minX })
        let right = run.map { lines[$0].bounds.maxX }.max() ?? 0
        let textRight = PDFLayoutGlyphs.median(run.map { lines[$0].bounds.maxX })
        // The size of the running text in this run. Every character counts, so a
        // run that holds a diagram's many small labels still measures its prose.
        let size = PDFLayoutGlyphs.bodyFontSize(run.map { lines[$0] }, outside: [])
        func inTextSize(_ line: LayoutLine) -> Bool { abs(line.fontSize - size) <= 0.15 * size }
        var gaps: [CGFloat] = []
        var textGaps: [CGFloat] = []
        for (above, below) in zip(run, run.dropFirst()) {
            let gap = lines[above].baseline - lines[below].baseline
            guard gap > 0 else { continue }
            gaps.append(gap)
            if inTextSize(lines[above]), inTextSize(lines[below]) { textGaps.append(gap) }
        }
        // Paragraph breaks are the large gaps, so the regular leading is near the
        // bottom of the distribution, not its middle. Gaps tighter than a line are
        // stacked formula lines, not leading, and must not pull the estimate down.
        let regular = (textGaps.isEmpty ? gaps : textGaps).filter { $0 >= 0.85 * size }
        let leading = regular.isEmpty ? 1.2 * size : PDFLayoutGlyphs.percentile(regular, 0.25)
        return Metrics(left: left, right: right, textRight: textRight, leading: leading)
    }
}

/// Clusters painted graphics into figure regions.
enum PDFLayoutFigures {
    /// Regions big enough to hold a figure. Thin rules, underlines and page-sized
    /// backgrounds are dropped so that captions and footnotes stay text.
    static func regions(graphics: [PDFGraphic], pageBox: CGRect) -> [CGRect] {
        let pageArea = max(pageBox.width * pageBox.height, 1)
        var boxes: [CGRect] = []
        for graphic in graphics {
            let box = graphic.bounds.intersection(pageBox)
            guard !box.isNull, box.width > 1, box.height > 1 else { continue }
            guard box.width * box.height < 0.8 * pageArea else { continue }
            if graphic.kind == .path, isRule(box) { continue }
            boxes.append(box)
        }
        guard !boxes.isEmpty else { return [] }
        let margin: CGFloat = 6
        var merged = boxes
        var changed = true
        while changed {
            changed = false
            var result: [CGRect] = []
            for box in merged {
                if let i = result.firstIndex(where: { $0.insetBy(dx: -margin, dy: -margin).intersects(box) }) {
                    result[i] = result[i].union(box)
                    changed = true
                } else {
                    result.append(box)
                }
            }
            merged = result
        }
        let minArea = 0.005 * pageArea
        return merged.filter { $0.width >= 20 && $0.height >= 16 && $0.width * $0.height >= minArea }
    }

    /// Short horizontal rules, used as a hint that a footnote follows.
    static func rules(graphics: [PDFGraphic]) -> [CGRect] {
        graphics.filter { $0.kind == .path }.map(\.bounds).filter(isRule)
    }

    private static func isRule(_ box: CGRect) -> Bool {
        (box.height <= 2.5 && box.width >= 10) || (box.width <= 2.5 && box.height >= 10)
    }
}

/// Decides the class of every line and the role of every paragraph.
enum PDFLayoutRoles {
    static func classify(_ lines: inout [LayoutLine], runs: [[Int]], pageBox: CGRect,
                         figures: [CGRect], tables: [CGRect], hints: [CGRect], bodySize: CGFloat) {
        for i in lines.indices {
            let point = CGPoint(x: lines[i].bounds.midX, y: lines[i].baseline)
            lines[i].hint = hints.firstIndex { $0.contains(point) }
        }
        for run in runs {
            let metrics = PDFLayoutColumns.metrics(for: run, lines: lines)
            for index in run {
                lines[index].lineClass = classifyLine(lines[index], metrics: metrics,
                                                      figures: figures, tables: tables,
                                                      pageBox: pageBox)
            }
            keepCaptionsAtBlockStart(run: run, lines: &lines, metrics: metrics)
            continueCaptions(run: run, lines: &lines, metrics: metrics, bodySize: bodySize)
            for (position, index) in run.enumerated() where lines[index].lineClass == .text {
                let next = position + 1 < run.count ? lines[run[position + 1]] : nil
                if isHeading(lines[index], bodySize: bodySize, nextIsBody: next?.lineClass == .text,
                             metrics: metrics) {
                    lines[index].lineClass = .heading
                }
            }
            continueHeadings(run: run, lines: &lines, metrics: metrics)
            continueFormulaChunks(run: run, lines: &lines)
        }
        markAuthorBlock(&lines, pageBox: pageBox, bodySize: bodySize)
    }

    /// A formula chunk set beside a text line on the same baseline continues that
    /// line: "Where the projections are parameter matrices W_i ∈ R^{...},
    /// W_i ∈ R^{...} and W^O ∈ R^{...}" is one sentence split into chunks by the
    /// wide gaps between them.
    private static func continueFormulaChunks(run: [Int], lines: inout [LayoutLine]) {
        for position in run.indices.dropFirst() {
            let index = run[position]
            let previous = lines[run[position - 1]]
            guard lines[index].lineClass == .formula else { continue }
            guard previous.lineClass == .text || previous.continues else { continue }
            let size = max(previous.fontSize, lines[index].fontSize)
            guard abs(previous.baseline - lines[index].baseline) <= 0.5 * size else { continue }
            lines[index].lineClass = .text
            lines[index].continues = true
        }
    }

    /// The block between the title and the "Abstract" heading holds the authors,
    /// their affiliations and their addresses. Names are not translated in a
    /// Japanese paper, so the whole block is left as it is.
    private static func markAuthorBlock(_ lines: inout [LayoutLine], pageBox: CGRect,
                                        bodySize: CGFloat) {
        guard let abstract = lines.first(where: isAbstractHeading) else { return }
        let margin = 0.5 * abstract.fontSize
        guard let title = lines.filter({ $0.baseline > abstract.baseline + margin })
            .max(by: { $0.fontSize < $1.fontSize }) else { return }
        // A real title is bigger than the body and sits in the top half of the page.
        guard title.fontSize >= 1.15 * bodySize, title.baseline > pageBox.midY else { return }
        for index in lines.indices {
            let baseline = lines[index].baseline
            guard baseline < title.baseline - 0.5 * title.fontSize,
                  baseline > abstract.baseline + margin else { continue }
            lines[index].lineClass = .other
        }
    }

    private static func isAbstractHeading(_ line: LayoutLine) -> Bool {
        var text = line.text.trimmingCharacters(in: .whitespaces).lowercased()
        while let last = text.last, ".:;".contains(last) { text.removeLast() }
        return text == "abstract"
    }

    /// A heading that wraps keeps its class on the following lines, so that the
    /// last line of a long heading does not become a paragraph of its own. A
    /// short line ends the heading.
    private static func continueHeadings(run: [Int], lines: inout [LayoutLine],
                                         metrics: PDFLayoutColumns.Metrics) {
        var heading: LayoutLine?
        for index in run {
            let line = lines[index]
            if line.lineClass == .heading {
                heading = line
                continue
            }
            guard let start = heading, line.lineClass == .text,
                  aligned(line, with: start),
                  start.baseline - line.baseline <= 1.45 * metrics.leading,
                  abs(line.fontSize - start.fontSize) <= 0.12 * start.fontSize,
                  !isShort(start, metrics: metrics) else {
                heading = nil
                continue
            }
            lines[index].lineClass = .heading
            heading = line
        }
    }

    /// "Figure 3." starts a caption only at the start of a block. In running text a
    /// line can begin with "Fig. 3)" or "Fig. 4. First, ..." when the sentence above
    /// wraps there: the line above is a full line of text at the normal spacing.
    private static func keepCaptionsAtBlockStart(run: [Int], lines: inout [LayoutLine],
                                                 metrics: PDFLayoutColumns.Metrics) {
        for position in run.indices.dropFirst() {
            let index = run[position]
            let previous = lines[run[position - 1]]
            guard lines[index].lineClass == .caption, previous.lineClass == .text else { continue }
            let line = lines[index]
            let gap = previous.baseline - line.baseline
            guard gap > 0, gap <= 1.2 * metrics.leading,
                  abs(previous.fontSize - line.fontSize) <= 0.12 * line.fontSize,
                  !isShort(previous, metrics: metrics) else { continue }
            lines[index].lineClass = .text
        }
    }

    /// A caption that wraps keeps its class on the following lines of the same
    /// block, so that the whole caption becomes one paragraph.
    private static func continueCaptions(run: [Int], lines: inout [LayoutLine],
                                         metrics: PDFLayoutColumns.Metrics, bodySize: CGFloat) {
        var caption: LayoutLine?
        for index in run {
            let line = lines[index]
            if line.lineClass == .caption {
                caption = line
                continue
            }
            guard let start = caption, line.lineClass == .text,
                  aligned(line, with: start),
                  start.baseline - line.baseline <= 1.45 * metrics.leading,
                  line.fontSize <= 1.15 * bodySize,
                  !isShort(start, metrics: metrics) else {
                caption = nil
                continue
            }
            lines[index].lineClass = .caption
            caption = line
        }
    }

    private static func classifyLine(_ line: LayoutLine, metrics: PDFLayoutColumns.Metrics,
                                     figures: [CGRect], tables: [CGRect],
                                     pageBox: CGRect) -> LayoutLineClass {
        if PDFLayoutTables.contains(tables, line: line) { return .other }
        if isFurniture(line, pageBox: pageBox) { return .furniture }
        if isFormula(line, metrics: metrics) { return .formula }
        if isCaption(line.text) { return .caption }
        guard line.nonSpace > 0, line.letters > 0 else { return .other }
        if line.style.isMonospace { return .other }
        if isLink(line.text) { return .other }
        let center = CGPoint(x: line.bounds.midX, y: line.bounds.midY)
        if figures.contains(where: { $0.contains(center) }) { return .other }
        return .text
    }

    private static func isFurniture(_ line: LayoutLine, pageBox: CGRect) -> Bool {
        let margin = 0.07 * pageBox.height
        let inMargin = line.baseline > pageBox.maxY - margin || line.baseline < pageBox.minY + margin
        guard inMargin else { return false }
        return line.letters == 0 || line.text.count <= 60
    }

    /// Two lines of one block start at the same edge, or share the same centre
    /// when the block is centred.
    private static func aligned(_ line: LayoutLine, with start: LayoutLine) -> Bool {
        let tolerance = 0.5 * line.fontSize
        return abs(line.bounds.minX - start.bounds.minX) <= tolerance
            || abs(line.bounds.midX - start.bounds.midX) <= tolerance
    }

    /// A line that ends well before the column does: the last line of a paragraph,
    /// and the end of a caption that wraps.
    static func isShort(_ line: LayoutLine, metrics: PDFLayoutColumns.Metrics) -> Bool {
        let typicalWidth = max(metrics.textRight - metrics.left, 1)
        return metrics.textRight - line.bounds.maxX > 1.5 * line.fontSize
            && line.bounds.width < 0.75 * typicalWidth
    }

    private static func isFormula(_ line: LayoutLine, metrics: PDFLayoutColumns.Metrics) -> Bool {
        guard line.strongMath > 0 else { return false }
        let ratio = Double(line.strongMath + line.weakMath) / Double(max(line.nonSpace, 1))
        if line.strongMath >= 2, ratio > 0.6 { return true }
        return isCentered(line, metrics: metrics)
    }

    /// A line centred in its column that carries mathematics is a display formula.
    /// A trailing equation number is ignored: it sits at the margin by design.
    private static func isCentered(_ line: LayoutLine, metrics: PDFLayoutColumns.Metrics) -> Bool {
        let (minX, maxX) = bodyExtent(line)
        let width = maxX - minX
        let columnWidth = max(metrics.right - metrics.left, 1)
        guard width > 0, width < 0.8 * columnWidth else { return false }
        let center = (minX + maxX) / 2
        return abs(center - (metrics.left + metrics.right) / 2) <= 0.06 * columnWidth
    }

    private static func bodyExtent(_ line: LayoutLine) -> (CGFloat, CGFloat) {
        var glyphs = line.glyphs
        while let last = glyphs.last, last.isSpace { glyphs.removeLast() }
        if glyphs.count >= 3, glyphs[glyphs.count - 1].unicode == ")" {
            var i = glyphs.count - 2
            var inner = 0
            while i >= 0, glyphs[i].unicode.count == 1,
                  glyphs[i].unicode.first!.isNumber || glyphs[i].unicode.first!.isLetter, inner < 2 {
                i -= 1
                inner += 1
            }
            if i >= 0, glyphs[i].unicode == "(", inner >= 1,
               glyphs[i].box.minX > line.bounds.minX + 0.6 * line.bounds.width {
                glyphs.removeSubrange(i...)
                while let last = glyphs.last, last.isSpace { glyphs.removeLast() }
            }
        }
        guard let low = glyphs.map(\.box.minX).min(), let high = glyphs.map(\.box.maxX).max() else {
            return (line.bounds.minX, line.bounds.maxX)
        }
        return (low, high)
    }

    private static func isCaption(_ text: String) -> Bool {
        guard text.first?.isUppercase == true else { return false }
        let lower = text.lowercased()
        for prefix in ["figure ", "fig. ", "fig ", "table ", "tab. "] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            if let first = rest.first, first.isNumber || first.isLetter { return true }
        }
        return false
    }

    private static func isLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("://") || lower.contains("www.") { return true }
        guard let at = lower.firstIndex(of: "@") else { return false }
        let tail = lower[lower.index(after: at)...]
        return tail.contains(".") && !tail.contains(" ")
    }

    private static func isHeading(_ line: LayoutLine, bodySize: CGFloat, nextIsBody: Bool,
                                  metrics: PDFLayoutColumns.Metrics) -> Bool {
        guard line.letters > 0, line.text.count <= 90 else { return false }
        // A heading is never set smaller than the body text and never ends a
        // sentence, which keeps a footnote marker like "1 A note." out.
        guard line.fontSize >= 0.95 * bodySize, !line.text.hasSuffix(".") else { return false }
        let bigger = line.fontSize >= 1.15 * bodySize
        // A run-in heading ("Residual Representations. In image ...") is bold only
        // at its start; the line is running text.
        let bold = isWhollyBold(line)
        // A full line of running text can start with a number ("2015 classification
        // competition. The ..."); a numbered heading is short or set apart.
        if hasSectionNumber(line.text) {
            return bigger || bold || isShort(line, metrics: metrics)
        }
        return (bigger || bold) && nextIsBody
    }

    private static func isWhollyBold(_ line: LayoutLine) -> Bool {
        let styled = proseGlyphs(line)
        return !styled.isEmpty && styled.allSatisfy(\.style.isBold)
    }

    /// The glyphs that show the style of the prose: no spaces and no mathematics,
    /// whose fonts say nothing about bold or serif text.
    private static func proseGlyphs(_ line: LayoutLine) -> [LayoutGlyph] {
        line.glyphs.filter { !$0.isSpace && $0.math != .strong && !$0.style.isMath }
    }

    /// Whether `next` carries on the paragraph of `previous` as far as bold and
    /// monospaced type tell. A bold heading line followed by a plain line starts a
    /// paragraph, and so does a line set wholly in bold after plain text. A bold
    /// run-in label at the start of a line ("Right: a residual network ...") or an
    /// italic phrase does not split a paragraph.
    static func continuesStyle(_ previous: LayoutLine, into next: LayoutLine) -> Bool {
        guard let end = proseGlyphs(previous).last, let start = proseGlyphs(next).first else {
            return previous.style.isBold == next.style.isBold
                && previous.style.isMonospace == next.style.isMonospace
        }
        // Code set in a monospaced font is never part of a prose paragraph.
        if previous.style.isMonospace != next.style.isMonospace { return false }
        switch (end.style.isBold, start.style.isBold) {
        case (true, false): return false
        case (false, true): return !isWhollyBold(next)
        default: return true
        }
    }

    private static func hasSectionNumber(_ text: String) -> Bool {
        var index = text.startIndex
        var digits = 0
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
            digits += 1
        }
        guard digits >= 1 else { return false }
        var dots = 0
        while index < text.endIndex, text[index] == "." {
            let after = text.index(after: index)
            guard after < text.endIndex, text[after].isNumber else { break }
            index = text.index(after: after)
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
            dots += 1
        }
        guard index < text.endIndex, text[index] == " " else { return false }
        let rest = text[index...].drop(while: { $0 == " " })
        return !rest.isEmpty && rest.contains(where: \.isLetter)
    }

    static func startsWithListMarker(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " })
        guard let first = trimmed.first else { return false }
        if "•◦▪▫‣∙·○●■□–".contains(first) { return true }
        let rest = trimmed.dropFirst()
        // "1." / "1)" / "(a)" / "a)" followed by a space.
        if first.isNumber {
            var index = trimmed.startIndex
            var digits = 0
            while index < trimmed.endIndex, trimmed[index].isNumber {
                index = trimmed.index(after: index)
                digits += 1
            }
            guard digits <= 3, index < trimmed.endIndex else { return false }
            if (trimmed[index] == "." || trimmed[index] == ")"),
               trimmed.index(after: index) < trimmed.endIndex,
               trimmed[trimmed.index(after: index)] == " " {
                return true
            }
            return false
        }
        if first == "(", rest.count >= 3, let letter = rest.first, letter.isLetter || letter.isNumber {
            let afterLetter = rest.dropFirst()
            if let close = afterLetter.first, close == ")", afterLetter.dropFirst().first == " " { return true }
        }
        if first.isLetter, let mark = rest.first, mark == ")" || mark == ".",
           rest.dropFirst().first == " " {
            return true
        }
        return false
    }

    static func role(of lines: [LayoutLine], bodySize: CGFloat, pageBox: CGRect,
                     rules: [CGRect]) -> PDFParagraph.Role {
        if lines.allSatisfy({ $0.lineClass == .formula }) { return .formula }
        if lines.contains(where: { $0.lineClass == .furniture }) { return .pageFurniture }
        if lines.contains(where: { $0.lineClass == .caption }) { return .caption }
        if lines.contains(where: { $0.lineClass == .heading }) { return .heading }
        if lines.contains(where: { $0.lineClass == .other }) { return .other }
        let text = lines.map(\.text).joined(separator: " ")
        guard text.contains(where: \.isLetter) else { return .other }
        if isTable(lines) { return .other }
        if isLabel(lines, text: text, bodySize: bodySize) { return .other }
        if startsWithListMarker(text) { return .listItem }
        if isFootnote(lines, bodySize: bodySize, pageBox: pageBox, rules: rules) { return .footnote }
        return .body
    }

    /// A figure label ("identity", "34-layer plain"): one short line set smaller
    /// than the body text that does not end a sentence. Translated, it would wrap
    /// into a column of a few characters inside the drawing.
    private static func isLabel(_ lines: [LayoutLine], text: String, bodySize: CGFloat) -> Bool {
        guard lines.count == 1, let line = lines.first, line.fontSize < 0.9 * bodySize else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !".!?:;".contains(last) else { return false }
        return trimmed.split(separator: " ").count <= 3
    }

    private static func isTable(_ lines: [LayoutLine]) -> Bool {
        guard lines.count >= 2 else { return false }
        return PDFLayoutGlyphs.median(lines.map { CGFloat($0.cells) }) >= 3
    }

    private static func isFootnote(_ lines: [LayoutLine], bodySize: CGFloat, pageBox: CGRect,
                                   rules: [CGRect]) -> Bool {
        guard let top = lines.first?.bounds.maxY else { return false }
        let inBottom = top < pageBox.minY + 0.35 * pageBox.height
        guard inBottom else { return false }
        let size = PDFLayoutGlyphs.median(lines.map(\.fontSize))
        if size < 0.92 * bodySize { return true }
        // A short rule drawn directly above the block, starting at its left edge,
        // is the classic footnote separator. A short line in a figure elsewhere on
        // the page is not.
        let left = lines.map(\.bounds.minX).min() ?? 0
        return rules.contains { rule in
            rule.maxY >= top && rule.maxY <= top + 3 * bodySize && rule.width < 0.5 * pageBox.width
                && abs(rule.minX - left) <= 2 * bodySize
        }
    }
}
