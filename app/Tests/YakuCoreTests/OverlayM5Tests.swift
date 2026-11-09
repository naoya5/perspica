import CoreGraphics
import Foundation
import Testing
@testable import YakuCore

// MARK: - tiling

@Suite("OCR tiling")
struct OCRTilingTests {
    @Test("a small picture is one tile")
    func smallPicture() {
        let tiles = OCRTiling.tiles(width: 800, height: 600)
        #expect(tiles.count == 1)
        #expect(tiles[0] == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test("a Retina-sized capture is cut into tiles no wider than the limit")
    func wideCapture() {
        let tiles = OCRTiling.tiles(width: 2940, height: 1912)
        #expect(tiles.count > 1)
        #expect(tiles.allSatisfy { $0.width <= OCRTiling.maximumTileSide && $0.height <= OCRTiling.maximumTileSide })
        // The tiles cover the whole picture...
        let union = tiles.reduce(CGRect.null) { $0.union($1) }
        #expect(union.minX == 0 && union.minY == 0)
        #expect(union.maxX == 2940 && union.maxY == 1912)
        // ...and neighbouring tiles overlap.
        let sorted = tiles.sorted { $0.minX < $1.minX }
        #expect(sorted[1].minX < sorted[0].maxX)
    }

    @Test("a line reported by two tiles is kept once")
    func dedupe() {
        let a = OCRLine(text: "General", rect: CGRect(x: 40, y: 84, width: 52, height: 12), confidence: 0.8)
        let b = OCRLine(text: "General", rect: CGRect(x: 41, y: 84, width: 52, height: 12), confidence: 0.95)
        let merged = OCRTiling.merge([[a], [b]])
        #expect(merged.count == 1)
        #expect(merged[0].confidence == 0.95)
    }

    @Test("a fragment of a whole-picture line is dropped, a new line is kept")
    func recovery() {
        let whole = [
            OCRLine(text: "The encoder is composed of a stack of six identical layers.",
                    rect: CGRect(x: 71, y: 142, width: 1251, height: 20), confidence: 1),
        ]
        // A seam fragment: the tile cut the same line at x = 1104, so its box
        // sits inside the whole line's box.
        let fragment = OCRLine(text: "identical layers.", rect: CGRect(x: 1104, y: 142, width: 218, height: 20), confidence: 1)
        let missed = OCRLine(text: "General", rect: CGRect(x: 40, y: 84, width: 52, height: 12), confidence: 1)
        let merged = OCRTiling.mergeRecovered(base: whole, extra: [fragment, missed])
        #expect(merged.count == 2)
        #expect(merged.contains { $0.text == "The encoder is composed of a stack of six identical layers." })
        #expect(merged.contains { $0.text == "General" })
        #expect(!merged.contains { $0.text == "identical layers." })
    }
}

// MARK: - reading order

@Suite("Overlay reading order")
struct OverlayReadingOrderTests {
    private func block(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 300, height: CGFloat = 20) -> OCRBlock {
        OCRBlock(lines: [OCRLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height), confidence: 1)])
    }

    @Test("a two column page reads column by column")
    func twoColumns() {
        // The prototype's order was 見出し → 左1 → 右1 → 右2 → 左2.
        let blocks = [
            block("heading", x: 72, y: 60, width: 140, height: 32),
            block("left one", x: 72, y: 142),
            block("right one", x: 748, y: 142),
            block("right two", x: 748, y: 255),
            block("left two", x: 72, y: 312),
        ]
        let arranged = OverlayReadingOrder.arrange(blocks)
        #expect(arranged.map(\.text) == ["heading", "left one", "left two", "right one", "right two"])
    }

    @Test("a single column page is unchanged")
    func singleColumn() {
        let blocks = [
            block("one", x: 96, y: 100, width: 1200),
            block("two", x: 96, y: 140, width: 1200),
            block("three", x: 96, y: 180, width: 1200),
        ]
        #expect(OverlayReadingOrder.arrange(blocks).map(\.text) == ["one", "two", "three"])
    }

    @Test("a heading above a sidebar is not two columns")
    func headerNotColumns() {
        // The two groups barely overlap vertically, so this is one column.
        let blocks = [
            block("title", x: 40, y: 20, width: 200, height: 30),
            block("body one", x: 40, y: 200, width: 200),
            block("body two", x: 40, y: 240, width: 200),
            block("aside", x: 900, y: 800, width: 200),
            block("aside two", x: 900, y: 840, width: 200),
        ]
        let arranged = OverlayReadingOrder.arrange(blocks)
        #expect(arranged.map(\.text) == ["title", "body one", "body two", "aside", "aside two"])
    }
}

// MARK: - weight

@Suite("Overlay emphasis")
struct OverlayEmphasisTests {
    /// A picture with white everywhere and black vertical bars `stroke` wide
    /// with `gap` between them, which is what a font weight looks like from
    /// above: a heavier weight covers more of the line.
    private func picture(width: Int, height: Int, stroke: Int, gap: Int, textRows: Int) -> PixelImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            guard y % 20 < textRows else { continue }
            for x in 0..<width {
                guard (x % (stroke + gap)) < stroke else { continue }
                let offset = (y * width + x) * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    @Test("thick strokes read as bold, thin ones do not")
    func weight() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 20)
        let bold = picture(width: 200, height: 20, stroke: 5, gap: 3, textRows: 12)
        let regular = picture(width: 200, height: 20, stroke: 2, gap: 9, textRows: 12)
        #expect(OverlayEmphasis.inkRatio(in: bold, block: rect) > OverlayEmphasis.inkRatio(in: regular, block: rect))
        #expect(OverlayEmphasis.isBold(in: bold, block: rect, text: "Attention Is All You Need",
                                        lineHeight: 34, medianLineHeight: 20))
        #expect(!OverlayEmphasis.isBold(in: regular, block: rect, text: "the dominant models",
                                         lineHeight: 20, medianLineHeight: 20))
    }

    @Test("a very short string is never called bold on ink alone")
    func shortString() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let bold = picture(width: 40, height: 20, stroke: 5, gap: 3, textRows: 12)
        #expect(!OverlayEmphasis.isBold(in: bold, block: rect, text: "12", lineHeight: 20, medianLineHeight: 20))
    }
}

// MARK: - the height rule

@Suite("OCR height rule")
struct OCRHeightRuleTests {
    private func line(_ text: String, y: CGFloat, height: CGFloat) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: 100, y: y, width: 300, height: height), confidence: 1)
    }

    @Test("a paragraph whose lines vary by a fifth stays one block")
    func paragraphTolerance() {
        // Measured on a columns sample: Vision's box for a line without
        // ascenders or descenders is about 20% shorter than its neighbours'.
        let lines = [
            line("The encoder is composed of a stack of six identical layers.", y: 142, height: 17.1),
            line("sub-layers. The first is a multi-head self-attention mechanism,", y: 169.5, height: 20.9),
            line("a simple, position-wise fully connected feed-forward network.", y: 198.8, height: 19.2),
            line("residual connection around each of the two sub-layers, followed", y: 226, height: 21.0),
            line("normalization.", y: 255.3, height: 16.7),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 5)
    }

    @Test("the title and description of a UI row merge, as the rule allows")
    func titleAndDescription() {
        // Measured on a UI sample: "Play a sound" (17.1pt box) and its
        // description (14.7pt) differ by 14%. The specification's 25% rule joins
        // them, and so would any rule strict enough to split them — it would
        // also split the paragraph above, whose lines differ by 21%. The rule is
        // therefore left alone.
        let lines = [
            line("Play a sound", y: 217.5, height: 17.1),
            line("Use the system alert sound", y: 240.7, height: 14.7),
        ]
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
    }
}
