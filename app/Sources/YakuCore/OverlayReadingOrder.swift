import CoreGraphics
import Foundation

/// Puts recognised blocks into the order a reader takes them in (SPEC 9).
///
/// Blocks are grouped top-to-bottom, left-to-right, which is right for a
/// single-column page but mixes up a two-column one: the prototype's order came
/// out 見出し → 左の1段落目 → 右の1 → 右の2 → 左の2. When the page is clearly two
/// columns — there is a vertical gutter no block crosses, both sides hold more
/// than one block, and the two sides run alongside each other — the blocks are
/// ordered column by column instead: all of the left column top to bottom, then
/// all of the right.
public enum OverlayReadingOrder {
    /// A gutter must be at least this share of the page's width to count.
    public static let minimumGutterRatio: CGFloat = 0.04
    /// The two columns must overlap vertically by at least this share of the
    /// shorter column's height, so a header above a sidebar is not mistaken for
    /// two columns.
    public static let minimumVerticalOverlapRatio: CGFloat = 0.4
    /// Both columns must hold at least this many blocks.
    public static let minimumColumnBlocks = 2

    /// The blocks in reading order.
    public static func arrange(_ blocks: [OCRBlock]) -> [OCRBlock] {
        guard blocks.count >= minimumColumnBlocks * 2 else { return topToBottom(blocks) }
        let pageWidth = blocks.reduce(CGFloat.zero) { max($0, $1.rect.maxX) }
            - blocks.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.rect.minX) }
        guard pageWidth > 0 else { return topToBottom(blocks) }

        guard let split = columnSplit(blocks, pageWidth: pageWidth) else {
            return topToBottom(blocks)
        }
        return topToBottom(split.left) + topToBottom(split.right)
    }

    /// The split with the widest gutter, if any satisfies the rules.
    static func columnSplit(_ blocks: [OCRBlock], pageWidth: CGFloat) -> (left: [OCRBlock], right: [OCRBlock])? {
        let byLeft = blocks.sorted { $0.rect.minX < $1.rect.minX }
        var best: (gutter: CGFloat, left: [OCRBlock], right: [OCRBlock])?

        for index in minimumColumnBlocks...(byLeft.count - minimumColumnBlocks) {
            let left = Array(byLeft[0..<index])
            let right = Array(byLeft[index...])
            let leftMaxX = left.reduce(CGFloat.zero) { max($0, $1.rect.maxX) }
            let rightMinX = right.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.rect.minX) }
            let gutter = rightMinX - leftMaxX
            guard gutter >= pageWidth * minimumGutterRatio else { continue }
            guard verticalOverlap(left, right) >= minimumVerticalOverlapRatio else { continue }
            if best == nil || gutter > best!.gutter {
                best = (gutter, left, right)
            }
        }

        guard let best else { return nil }
        return (best.left, best.right)
    }

    /// How much of the shorter column's height the two share vertically.
    static func verticalOverlap(_ left: [OCRBlock], _ right: [OCRBlock]) -> CGFloat {
        guard let leftRange = verticalRange(left), let rightRange = verticalRange(right) else { return 0 }
        let shared = min(leftRange.upperBound, rightRange.upperBound) - max(leftRange.lowerBound, rightRange.lowerBound)
        let shorter = min(leftRange.upperBound - leftRange.lowerBound, rightRange.upperBound - rightRange.lowerBound)
        guard shorter > 0 else { return 0 }
        return max(0, shared) / shorter
    }

    private static func verticalRange(_ blocks: [OCRBlock]) -> ClosedRange<CGFloat>? {
        guard !blocks.isEmpty else { return nil }
        let top = blocks.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.rect.minY) }
        let bottom = blocks.reduce(CGFloat.zero) { max($0, $1.rect.maxY) }
        return top...bottom
    }

    /// Top to bottom, then left to right.
    public static func topToBottom(_ blocks: [OCRBlock]) -> [OCRBlock] {
        blocks.sorted { first, second in
            first.rect.minY == second.rect.minY
                ? first.rect.minX < second.rect.minX
                : first.rect.minY < second.rect.minY
        }
    }
}
