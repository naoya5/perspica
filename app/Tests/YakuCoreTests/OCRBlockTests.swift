import CoreGraphics
import Foundation
import Testing
@testable import YakuCore

/// A line laid out the way Vision reports one: a rect in image pixels with the
/// origin at the top left.
private func line(
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 300,
    height: CGFloat = 20,
    confidence: Double = 0.9
) -> OCRLine {
    OCRLine(
        text: text,
        rect: CGRect(x: x, y: y, width: width, height: height),
        confidence: confidence
    )
}

@Suite("OCR block grouping")
struct OCRBlockTests {
    @Test("a paragraph of evenly spaced lines becomes one block")
    func paragraph() {
        let lines = [
            line("The dominant sequence", x: 100, y: 100),
            line("transduction models are", x: 100, y: 126),
            line("based on complex networks.", x: 100, y: 152),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 3)
        #expect(blocks[0].text == "The dominant sequence transduction models are based on complex networks.")
    }

    @Test("a paragraph break starts a new block")
    func paragraphBreak() {
        let lines = [
            line("First paragraph line one.", x: 100, y: 100),
            line("First paragraph line two.", x: 100, y: 126),
            // A 40pt gap is more than 0.8 × the 20pt line height.
            line("Second paragraph begins here.", x: 100, y: 186),
            line("Second paragraph continues.", x: 100, y: 212),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "First paragraph line one. First paragraph line two.")
        #expect(blocks[1].text == "Second paragraph begins here. Second paragraph continues.")
    }

    @Test("a two column page stays in two blocks")
    func twoColumns() {
        var lines: [OCRLine] = []
        for row in 0..<6 {
            let y = CGFloat(100 + row * 26)
            lines.append(line("Left column line \(row).", x: 60, y: y, width: 280))
            lines.append(line("Right column line \(row).", x: 420, y: y, width: 280))
        }
        // Deliberately out of order, the way Vision can return them.
        let blocks = OCRBlockBuilder.blocks(from: lines.shuffled())
        #expect(blocks.count == 2)
        #expect(blocks[0].lines.allSatisfy { $0.rect.minX == 60 })
        #expect(blocks[1].lines.allSatisfy { $0.rect.minX == 420 })
        #expect(blocks[0].text.contains("Left column line 0."))
        #expect(blocks[1].text.contains("Right column line 5."))
    }

    @Test("a line that is a different size starts a new block")
    func differentHeight() {
        let lines = [
            line("Body text at twenty points.", x: 100, y: 100, height: 20),
            // 30 is more than 25% taller than 20.
            line("A much larger heading line.", x: 100, y: 124, height: 30),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 2)
    }

    @Test("lines that neither line up nor overlap start a new block")
    func noAlignmentNoOverlap() {
        let lines = [
            line("A label on the left.", x: 40, y: 100, width: 200),
            line("A far away value.", x: 700, y: 104, width: 200),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 2)
    }

    @Test("overlapping lines join even when their left edges differ")
    func overlapJoins() {
        let lines = [
            line("The first line of the run.", x: 100, y: 100, width: 300),
            // Indented 30pt, still overlapping by far more than half.
            line("The second, indented line.", x: 130, y: 126, width: 300),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
    }

    @Test("a line ending in a hyphen is joined without it")
    func hyphenJoin() {
        let lines = [
            line("We propose a new simple network architec-", x: 100, y: 100),
            line("ture, the Transformer.", x: 100, y: 126),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "We propose a new simple network architecture, the Transformer.")
    }

    @Test("Japanese lines are joined without a space")
    func cjkJoin() {
        let lines = [
            line("画面の文字を読み取り、", x: 100, y: 100),
            line("訳を元の位置に重ねる。", x: 100, y: 126),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks[0].text == "画面の文字を読み取り、訳を元の位置に重ねる。")
    }

    @Test("a line below the confidence floor is left out of the text")
    func lowConfidence() {
        let lines = [
            line("This line is read well.", x: 100, y: 100),
            line("Th1s 1ine is garbled.", x: 100, y: 126, confidence: 0.29),
            line("This line is read well too.", x: 100, y: 152),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        // The garbled line still holds the paragraph together, so it stays one
        // block; it is only left out of the text.
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 2)
        #expect(!blocks[0].text.contains("garbled"))
        #expect(blocks[0].text == "This line is read well. This line is read well too.")
        // The extent still covers the line that was dropped.
        #expect(blocks[0].rect.height == 72)
    }

    @Test("a block of nothing but garbled lines is dropped")
    func allLowConfidence() {
        let lines = [
            line("j8s0d9f", x: 100, y: 100, confidence: 0.1),
            line("9d8f7s6", x: 100, y: 126, confidence: 0.2),
        ]
        #expect(OCRBlockBuilder.blocks(from: lines).isEmpty)
    }

    @Test("a blank line is dropped")
    func blankLine() {
        let lines = [
            line("Real text here.", x: 100, y: 100),
            line("   ", x: 100, y: 126),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 1)
    }

    @Test("blocks come back in reading order, top to bottom")
    func readingOrder() {
        let lines = [
            line("Second block.", x: 100, y: 300),
            line("First block.", x: 100, y: 100),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.map(\.text) == ["First block.", "Second block."])
    }

    @Test("a block's rect is the union of its lines")
    func unionRect() {
        let lines = [
            line("Top line.", x: 100, y: 100, width: 300, height: 20),
            line("Bottom line.", x: 100, y: 126, width: 260, height: 20),
        ]
        let block = OCRBlockBuilder.blocks(from: lines)[0]
        #expect(block.rect.minX == 100)
        #expect(block.rect.minY == 100)
        #expect(block.rect.width == 300)
        #expect(block.rect.height == 46)
        #expect(block.confidence == 0.9)
    }

    @Test("the confidence floor is 0.3 and the gap ratio is 0.8")
    func constants() {
        #expect(OCRBlockBuilder.minimumConfidence == 0.3)
        #expect(OCRBlockBuilder.gapRatio == 0.8)
        #expect(OCRBlockBuilder.heightTolerance == 0.25)
        #expect(OCRBlockBuilder.lineLengthRatio == 0.7)
        #expect(OCRBlockBuilder.horizontalOverlap(
            CGRect(x: 0, y: 0, width: 100, height: 10),
            CGRect(x: 60, y: 0, width: 100, height: 10)
        ) == 40)
    }

    @Test("a short title above a long description is two blocks, not a wrap")
    func titleAboveDescription() {
        // The UI sample's own pair: `Play a sound` is 88px wide over a 157px
        // description, so 0.56 — the two are separate rows (M5.md 8.1).
        let lines = [
            line("Play a sound", x: 100, y: 100, width: 88, height: 17),
            line("Use the system alert sound", x: 100, y: 123, width: 157, height: 15),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "Play a sound")
        #expect(blocks[1].text == "Use the system alert sound")
        // Each is drawn at its own width, not at the other's.
        #expect(blocks[0].rect.width == 88)
        #expect(blocks[1].rect.width == 157)
    }

    @Test("a wrapped line stays in its paragraph")
    func wrappedLineStays() {
        // The narrowest pair the samples actually wrapped is 0.92 (M5.md 8.1),
        // so a line above at 0.92 of the line below it is a wrap, not a row.
        let lines = [
            line("That is, the output of each sub-layer", x: 100, y: 100, width: 280),
            line("Sublayer(x) is the function implemented.", x: 100, y: 126, width: 304),
        ]
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
    }

    @Test("the split sits at 0.7 of the next line's width")
    func lineLengthBoundary() {
        let wide = line("A long description of the setting.", x: 100, y: 126, width: 200)
        // Just under the ratio: the line above is a short title, so the line
        // below it is a row of its own and does not join.
        #expect(!OCRBlockBuilder.follows(wide, line("Title", x: 100, y: 100, width: 138)))
        // Just over: the line above is nearly as wide, so it is a wrapped line.
        #expect(OCRBlockBuilder.follows(wide, line("A wrapped line of text.", x: 100, y: 100, width: 142)))
    }

    @Test("a paragraph's short last line does not split it off")
    func shortLastLine() {
        // Nothing follows the short line, so the rule has nothing to compare it
        // with: the article stays whole (M5.md 8.1).
        let lines = [
            line("The dominant sequence transduction", x: 100, y: 100, width: 300),
            line("models are based on complex networks.", x: 100, y: 126, width: 300),
            line("Attention is all you need.", x: 100, y: 152, width: 150),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 3)
    }

    @Test("two short lines in a row are still separate rows")
    func twoShortLines() {
        let lines = [
            line("Group by app", x: 100, y: 100, width: 94, height: 15),
            line("Collect alerts from one app together", x: 100, y: 122, width: 207, height: 13),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines)
        #expect(blocks.count == 2)
    }

    @Test("an empty page has no blocks")
    func empty() {
        #expect(OCRBlockBuilder.blocks(from: []).isEmpty)
    }

    @Test("a block's line height is one line's, not the whole block's")
    func lineHeight() {
        let lines = [
            line("The dominant sequence", x: 100, y: 100, height: 20),
            line("transduction models are", x: 100, y: 126, height: 22),
            line("based on complex networks.", x: 100, y: 152, height: 21),
        ]
        let block = OCRBlockBuilder.blocks(from: lines)[0]
        #expect(block.rect.height == 73)
        #expect(block.lineHeight == 21)
        #expect(OCRBlock(lines: [], rect: CGRect(x: 0, y: 0, width: 10, height: 30)).lineHeight == 30)
    }
}
