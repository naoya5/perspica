import CoreGraphics
import Foundation

/// Splits a capture into pieces Vision reads reliably, then merges the results
/// (SPEC 9).
///
/// Vision's text detector drops small text on a large picture. On the 1440×900
/// UI sample the 14-point sidebar labels were not reported at all, while the
/// same picture cropped to 1400 pixels wide read every one of them, and
/// cropping to a narrower strip read them reliably. A Retina capture is several
/// thousand pixels across, so the capture is cut into overlapping tiles and the
/// lines are merged. Tiling is also *faster*: Vision's own cost blows up on a
/// large image (measured 0.78s for one 2880×1800 pass against 0.31s for three
/// tiles of the same picture).
public enum OCRTiling {
    /// The longest side one tile may have. Above this Vision starts missing
    /// small text (measured on the UI sample: 1400 is safe, 1416 is not, and the
    /// behaviour is unstable right at the edge, so stay well below).
    public static let maximumTileSide: CGFloat = 1200
    /// How much neighbouring tiles overlap, so a line on a seam is whole in one
    /// of them.
    public static let overlap: CGFloat = 96

    /// The tiles to recognise, in image pixels with the origin at the top left.
    public static func tiles(width: Int, height: Int) -> [CGRect] {
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard w > 0, h > 0 else { return [] }
        let columns = slices(length: w)
        let rows = slices(length: h)
        var rects: [CGRect] = []
        rects.reserveCapacity(columns.count * rows.count)
        for row in rows {
            for column in columns {
                rects.append(CGRect(x: column.start, y: row.start, width: column.length, height: row.length))
            }
        }
        return rects
    }

    private struct Slice {
        let start: CGFloat
        let length: CGFloat
    }

    private static func slices(length: CGFloat) -> [Slice] {
        guard length > maximumTileSide else { return [Slice(start: 0, length: length)] }
        var result: [Slice] = []
        var start: CGFloat = 0
        while true {
            let tileLength = min(maximumTileSide, length - start)
            result.append(Slice(start: start, length: tileLength))
            if start + tileLength >= length { break }
            let next = start + tileLength - overlap
            guard next > start else { break }
            start = next
        }
        return result
    }

    /// Merges the lines read from overlapping tiles. A line on a seam is
    /// reported by both tiles; the duplicate is dropped, keeping the more
    /// confident reading.
    public static func merge(_ groups: [[OCRLine]]) -> [OCRLine] {
        var kept: [OCRLine] = []
        for group in groups {
            for line in group {
                if let index = kept.firstIndex(where: { isDuplicate($0, line) }) {
                    if line.confidence > kept[index].confidence {
                        kept[index] = line
                    }
                } else {
                    kept.append(line)
                }
            }
        }
        return kept
    }

    /// Adds the lines a tile found to the lines the whole-picture pass found,
    /// keeping only the ones the whole-picture pass did not already cover.
    ///
    /// The whole-picture pass reads long lines whole, but misses small text
    /// (see `OCRTiling`); the tiles see the small text, but cut any line that
    /// crosses a seam into two fragments. Taking the whole-picture lines as the
    /// base and adding only the tile lines that sit outside every base line
    /// keeps the long lines intact and recovers the small text. A fragment of a
    /// base line falls inside that line's box, so it is dropped.
    public static func mergeRecovered(base: [OCRLine], extra: [OCRLine]) -> [OCRLine] {
        var kept = base
        for line in extra {
            let covered = base.contains { contains($0, line) }
            guard !covered else { continue }
            if let index = kept.firstIndex(where: { isDuplicate($0, line) }) {
                if line.confidence > kept[index].confidence {
                    kept[index] = line
                }
            } else {
                kept.append(line)
            }
        }
        return kept
    }

    /// True when `inner` sits mostly inside `outer`, so it is a fragment of it.
    public static func contains(_ outer: OCRLine, _ inner: OCRLine) -> Bool {
        let intersection = outer.rect.intersection(inner.rect)
        guard !intersection.isNull else { return false }
        let area = inner.rect.width * inner.rect.height
        guard area > 0 else { return false }
        return (intersection.width * intersection.height) / area >= 0.5
    }

    /// True when two lines are the same reading of the same text: their boxes
    /// almost coincide and the text matches.
    public static func isDuplicate(_ first: OCRLine, _ second: OCRLine) -> Bool {
        let a = first.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = second.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, a == b else { return false }
        let intersection = first.rect.intersection(second.rect)
        guard !intersection.isNull else { return false }
        let smaller = min(first.rect.width * first.rect.height, second.rect.width * second.rect.height)
        guard smaller > 0 else { return false }
        return (intersection.width * intersection.height) / smaller >= 0.5
    }
}
