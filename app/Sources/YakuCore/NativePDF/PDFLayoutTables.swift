import CoreGraphics
import Foundation

/// Finds the regions of a page that hold a table.
///
/// A table is recognised from two signals, either of which is enough:
/// - three or more horizontal rules with the same extent: the table sits
///   between the top and the bottom rule of the group;
/// - three or more consecutive rows that split into the same column starts and
///   are mostly numbers, for tables drawn without rules.
/// Two-column prose never matches the second signal: a row of it has one cell
/// per column, and a table row needs three.
enum PDFLayoutTables {
    /// Regions covered by a table, in page space.
    static func regions(lines: [LayoutLine], graphics: [PDFGraphic], pageBox: CGRect) -> [CGRect] {
        ruleRegions(graphics: graphics, pageBox: pageBox) + gridRegions(lines: lines)
    }

    /// True when the line sits inside a table region. The centre of the line
    /// decides, so that a row touching the top rule still counts as a row.
    static func contains(_ regions: [CGRect], line: LayoutLine) -> Bool {
        guard !regions.isEmpty else { return false }
        let point = CGPoint(x: line.bounds.midX, y: line.bounds.midY)
        return regions.contains { $0.contains(point) }
    }

    // MARK: - Rules

    /// The area between the outermost rules of a group of aligned rules. A
    /// table's rules share one extent, so grouping by extent separates the
    /// table's rules from an unrelated rule elsewhere on the page.
    private static func ruleRegions(graphics: [PDFGraphic], pageBox: CGRect) -> [CGRect] {
        let minimumWidth = max(0.2 * pageBox.width, 40)
        let rules = graphics.compactMap { graphic -> CGRect? in
            guard graphic.kind == .path else { return nil }
            let box = graphic.bounds
            // A filled rule is a few points tall, a stroked one has no height.
            guard box.height <= 4, box.width >= minimumWidth else { return nil }
            return box
        }
        var groups: [[CGRect]] = []
        for rule in rules.sorted(by: { $0.minX < $1.minX }) {
            if let index = groups.firstIndex(where: { group in
                abs(group[0].minX - rule.minX) <= 4 && abs(group[0].maxX - rule.maxX) <= 4
            }) {
                groups[index].append(rule)
            } else {
                groups.append([rule])
            }
        }
        return groups.compactMap { group in
            guard group.count >= 3 else { return nil }
            let top = group.map(\.maxY).max() ?? 0
            let bottom = group.map(\.minY).min() ?? 0
            let left = group.map(\.minX).min() ?? 0
            let right = group.map(\.maxX).max() ?? 0
            // A handful of rules across a whole page is a frame, not a table.
            guard top - bottom >= 20, top - bottom <= 0.9 * pageBox.height else { return nil }
            return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
    }

    // MARK: - Rows without rules

    private static func gridRegions(lines: [LayoutLine]) -> [CGRect] {
        let rows = tableRows(lines: lines)
        var regions: [CGRect] = []
        var start = 0
        while start < rows.count {
            var end = start + 1
            while end < rows.count, adjacent(rows[end - 1], rows[end]) { end += 1 }
            // A block may start part way into a run of rows, so try every window.
            var position = start
            while end - position >= 3 {
                if let region = gridRegion(Array(rows[position..<end])) {
                    regions.append(region)
                    break
                }
                position += 1
            }
            start = end
        }
        return regions
    }

    /// Lines grouped by baseline, each row left to right.
    private static func tableRows(lines: [LayoutLine]) -> [[LayoutLine]] {
        let sorted = lines.filter { $0.nonSpace > 0 }.sorted { lhs, rhs in
            if lhs.baseline != rhs.baseline { return lhs.baseline > rhs.baseline }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var rows: [[LayoutLine]] = []
        for line in sorted {
            if let reference = rows.last?.first,
               abs(reference.baseline - line.baseline) <= 0.5 * max(reference.fontSize, line.fontSize) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
    }

    private static func adjacent(_ above: [LayoutLine], _ below: [LayoutLine]) -> Bool {
        guard let top = above.first, let bottom = below.first else { return false }
        let gap = top.baseline - bottom.baseline
        return gap >= 0 && gap <= 1.6 * max(top.fontSize, bottom.fontSize)
    }

    /// A block of rows that share at least three column starts and are mostly
    /// numbers.
    private static func gridRegion(_ rows: [[LayoutLine]]) -> CGRect? {
        guard rows.count >= 3 else { return nil }
        let cells = rows.map { row in row.flatMap(cells(of:)) }
        guard cells.allSatisfy({ $0.count >= 3 }) else { return nil }
        let size = PDFLayoutGlyphs.median(rows.flatMap { $0.map(\.fontSize) })
        let tolerance = 0.5 * size
        var columns: [CGFloat] = []
        for row in cells {
            for cell in row {
                guard !columns.contains(where: { abs($0 - cell.start) <= tolerance }) else { continue }
                let support = cells.filter { other in
                    other.contains { abs($0.start - cell.start) <= tolerance }
                }.count
                if support >= 3 { columns.append(cell.start) }
            }
        }
        guard columns.count >= 3 else { return nil }
        let all = cells.flatMap { $0 }
        let numeric = all.filter { isNumeric($0.text) }.count
        guard 2 * numeric >= all.count else { return nil }
        return rows.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    /// The cells of one piece of a row: its glyphs split wherever the gap is
    /// wide enough to be a column gutter.
    private static func cells(of line: LayoutLine) -> [(start: CGFloat, text: String)] {
        var cells: [(start: CGFloat, text: String)] = []
        var start: CGFloat?
        var text = ""
        var rightEdge: CGFloat?
        for glyph in line.glyphs {
            guard !glyph.isSpace else { continue }
            if let edge = rightEdge, glyph.box.minX - edge > 2 * line.fontSize {
                if let begin = start { cells.append((begin, text)) }
                start = nil
                text = ""
            }
            if start == nil { start = glyph.box.minX }
            text += glyph.unicode
            rightEdge = max(rightEdge ?? glyph.box.minX, glyph.box.maxX)
        }
        if let begin = start { cells.append((begin, text)) }
        return cells
    }

    /// A cell that holds a number: it has a digit and no word.
    private static func isNumeric(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && !text.contains(where: \.isLetter)
    }
}
