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

    @Test("a row whose title and description are the same width splits on size")
    func sizeRuleSplitsSameWidthRow() {
        // The UI sample's `Show in Lock Screen` (146.5px, 15pt) over `Keep
        // recent items visible` (144.4px, 12pt): 1.01 of its width, so no width
        // rule can split it, but the sizes differ by 20% (M5.md 9.2).
        let lines = [
            line("Show in Lock Screen", x: 100, y: 100, width: 146.5, height: 17),
            line("Keep recent items visible", x: 100, y: 123, width: 144.4, height: 15),
        ]
        let sizes = [15.0, 12.0]
        let blocks = OCRBlockBuilder.blocks(from: lines) { line in
            sizes[line.text == "Show in Lock Screen" ? 0 : 1]
        }
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "Show in Lock Screen")
        #expect(blocks[1].text == "Keep recent items visible")
    }

    @Test("lines within 8% of each other stay one block")
    func sizeRuleKeepsNearSizes() {
        // A paragraph mixing Japanese and English lines reads 1.1% apart at
        // one size (M5.md 9.2), so it must not split.
        let lines = [
            line("エンコーダは、同一の層が6層積層された", x: 100, y: 100, width: 400),
            line("multi-head self-attention 機構であり、", x: 100, y: 126, width: 400),
            line("We employ a residual connection", x: 100, y: 152, width: 400),
        ]
        let sizes: [String: CGFloat] = [
            "エンコーダは、同一の層が6層積層された": 17.18,
            "multi-head self-attention 機構であり、": 17.07,
            "We employ a residual connection": 16.99,
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines) { sizes[$0.text] }
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 3)
    }

    @Test("the size split sits at 8%")
    func sizeToleranceValue() {
        #expect(OCRBlockBuilder.sizeTolerance == 0.08)
        let lines = [
            line("Title", x: 100, y: 100, width: 100),
            line("Description", x: 100, y: 123, width: 100),
        ]
        func splits(_ first: CGFloat, _ second: CGFloat) -> Bool {
            OCRBlockBuilder.blocks(from: lines) { $0.text == "Title" ? first : second }.count == 2
        }
        // 1.16 / 1.0 is 16%, over the tolerance; 1.08 / 1.0 is exactly 8%.
        #expect(splits(1.16, 1.0))
        #expect(!splits(1.07, 1.0))
        #expect(!splits(1.0, 1.0))
    }

    @Test("the size rule is skipped when a line's size is unknown")
    func sizeRuleSkippedWithoutSizes() {
        let lines = [
            line("Show in Lock Screen", x: 100, y: 100, width: 146.5, height: 17),
            line("Keep recent items visible", x: 100, y: 123, width: 144.4, height: 15),
        ]
        // Without sizes the two lines are one run, as M5 found.
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
        // And a line whose size cannot be measured is left to the geometry.
        #expect(OCRBlockBuilder.blocks(from: lines) { $0.text == "Show in Lock Screen" ? 15 : nil }.count == 1)
    }

    @Test("the size rule only ever splits, never joins")
    func sizeRuleOnlySplits() {
        // Two lines the geometric rules keep apart, at the same size, stay
        // apart: the size rule cannot pull them together.
        let lines = [
            line("Group by app", x: 100, y: 100, width: 94, height: 15),
            line("Collect alerts from one app together", x: 100, y: 122, width: 207, height: 13),
        ]
        let blocks = OCRBlockBuilder.blocks(from: lines) { _ in 14 }
        #expect(blocks.count == 2)
    }
}

/// The wrap rule, which is what the user's screen needed: a bullet's second
/// line came back in a box a third shorter than the line above it, and the
/// height rule cut it off and translated the fragment alone (M6.md 2.2).
///
/// The numbers are real. `userLog` is the user's own log from the
/// 2026-11-08T10:33:52Z run, which gives the boxes but not the rows; the gap
/// there is the one a 17-point line has between two ink boxes (16 and 14 pixels
/// tall on a 20-pixel pitch). `sample` is what `tools/make-samples.swift`'s
/// `list()` produces, read back with `--demo-dump-blocks`.
@Suite("OCR wrapped lines")
struct OCRWrapTests {
    /// `• Keeps you informed. …` over `one outcome.`, from the user's log.
    private func userLog() -> [OCRLine] {
        [
            line("• Keeps you informed. It reports progress at each milestone, asks when a decision is needed, and aggregates the results into",
                 x: 69, y: 435, width: 971, height: 16),
            line("one outcome.", x: 94, y: 455, width: 92, height: 14),
        ]
    }

    /// The same pair from the M6 sample, whose boxes are 23.4 and 16.7 tall:
    /// 28.6% apart, which is the height rule's own limit and over it.
    private func sample() -> [OCRLine] {
        [
            line("• Keeps you informed. It reports progress at each milestone, asks when a decision is needed, and aggregates the results into",
                 x: 69.1, y: 435.0, width: 948, height: 23.4),
            line("one outcome.", x: 94.2, y: 464.7, width: 107, height: 16.7),
        ]
    }

    @Test("a short continuation line joins the line above it")
    func continuationJoins() {
        for lines in [userLog(), sample()] {
            let blocks = OCRBlockBuilder.blocks(from: lines)
            #expect(blocks.count == 1)
            #expect(blocks[0].lines.count == 2)
            #expect(blocks[0].text.hasSuffix("one outcome."))
        }
    }

    @Test("the wrap rule is what joins each pair, and a different rule split each")
    func eachPairWasSplitByADifferentRule() {
        // The user's pair is within the height tolerance (16 and 14 are 12.5%
        // apart), so the height rule kept it; what split it was the **size**
        // rule, reading 12.0 from the box against 18.5 measured (the user's own
        // log). `TextInk.isInk` is what made the box value necessary, and the
        // wrap rule is what makes it harmless.
        let user = userLog()
        let userTaller = max(user[0].rect.height, user[1].rect.height)
        let userShorter = min(user[0].rect.height, user[1].rect.height)
        #expect(userTaller - userShorter <= OCRBlockBuilder.heightTolerance * userTaller)
        let userSizes: (OCRLine) -> CGFloat? = { $0.rect.height <= 14 ? 12.0 : 18.5 }
        #expect(OCRBlockBuilder.blocks(from: user, sizeOf: userSizes).count == 1)

        // The sample's pair is 28.6% apart, over the height tolerance, so the
        // height rule is what would have split it.
        let listed = sample()
        let listedTaller = max(listed[0].rect.height, listed[1].rect.height)
        let listedShorter = min(listed[0].rect.height, listed[1].rect.height)
        #expect(listedTaller - listedShorter > OCRBlockBuilder.heightTolerance * listedTaller)
    }

    @Test("the hanging indent of a bullet's second line is not a new block")
    func hangingIndentJoins() {
        // 22pt to the right: under the text rather than under the marker.
        let lines = [
            line("• Briefs each agent. Agents don't see your conversation", x: 69, y: 280, width: 904, height: 21),
            line("the work.", x: 91, y: 307, width: 76, height: 20),
        ]
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
    }

    @Test("a new list item is never a continuation")
    func newItemIsNotAContinuation() {
        // The two bullets that follow each other in the user's log. Their own
        // spacing (58pt apart) already separates them, so the rule is checked
        // directly: a bullet is never a wrapped continuation, however close the
        // line is.
        let first = line("• Delegates first. It splits the goal into parts", x: 69, y: 203, width: 854, height: 19)
        let second = line("• Briefs each agent. Agents don't see your conversation", x: 69, y: 280, width: 904, height: 21)
        #expect(!OCRBlockBuilder.continuesSentence(second, first))
        #expect(OCRBlockBuilder.blocks(from: [first, second]).count == 2)
        // The same two lines with the bullet removed and a small gap *would*
        // join, which is what shows the bullet is doing the work: the only
        // difference between these two pairs is the marker.
        let above = line("It splits the goal into parts and", x: 69, y: 203, width: 854, height: 19)
        #expect(OCRBlockBuilder.continuesSentence(
            line("assigns each part to one agent.", x: 69, y: 226, width: 904, height: 21), above))
        #expect(!OCRBlockBuilder.continuesSentence(
            line("• assigns each part to one agent.", x: 69, y: 226, width: 904, height: 21), above))
    }

    @Test("a capital letter starts a new sentence, not a continuation")
    func capitalDoesNotContinue() {
        // The same shape with the description starting upper case. The wrap
        // rule leaves it alone, so the pair is back to the geometry, which
        // keeps a 25%-or-closer pair together.
        let lines = [
            line("• Keeps you informed. It reports progress", x: 69, y: 435, width: 971, height: 16),
            line("One outcome.", x: 94, y: 455, width: 92, height: 14),
        ]
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
        #expect(!OCRBlockBuilder.continuesSentence(lines[1], lines[0]))
    }

    @Test("the wrap rule waives the size rule for a continuation")
    func continuationBeatsTheSizeRule() {
        // 20 against 12 points is 40% apart, which splits on its own. A wrapped
        // continuation is never cut off by a size, because the size is what was
        // misread in the first place.
        let sizes: (OCRLine) -> CGFloat? = { $0.text.hasPrefix("•") ? 20 : 12 }
        #expect(OCRBlockBuilder.blocks(from: userLog(), sizeOf: sizes).count == 1)
        // The same sizes on the same boxes, with the text saying they are
        // separate, do split.
        let separate = [
            line("• Keeps you informed. It reports progress", x: 69, y: 435, width: 971, height: 16),
            line("One outcome.", x: 94, y: 455, width: 92, height: 14),
        ]
        #expect(OCRBlockBuilder.blocks(from: separate, sizeOf: sizes).count == 2)
    }

    @Test("the wrap rule leaves a Japanese paragraph to the height rule")
    func japaneseIsUnaffected() {
        let lines = [
            line("エンコーダは、同一の層が 6 層積層された構成となっている。", x: 72, y: 140, width: 900, height: 22),
            line("各層には 2 つのサブレイヤが存在する。", x: 72, y: 170, width: 420, height: 22),
        ]
        // No case, so the wrap rule never fires; the lines are the same height
        // and overlap, so the geometry keeps them together as it always did.
        #expect(!OCRBlockBuilder.continuesSentence(lines[1], lines[0]))
        #expect(OCRBlockBuilder.blocks(from: lines).count == 1)
    }

    @Test("the continuation signals")
    func continuationSignals() {
        func isContinuation(_ above: String, _ below: String) -> Bool {
            OCRBlockBuilder.continuesSentence(
                line(below, x: 100, y: 130),
                line(above, x: 100, y: 100)
            )
        }
        #expect(isContinuation("It reports progress at each milestone, and", "one outcome."))
        #expect(isContinuation("It doesn't do the work itself", "delegates the goal."))
        // A sentence that ended does not continue. A colon ends one too, which
        // is the brief's own list (`.` `!` `?` `:`).
        for ender in [".", "!", "?", ":", "。", "！", "？", "："] {
            #expect(!isContinuation("It reports progress\(ender)", "one outcome."), Comment(rawValue: ender))
        }
        // A closing mark after the full stop does not hide it.
        #expect(!isContinuation("It reports progress (see the plan.)", "one outcome."))
        // No punctuation at all, so the sentence is still going.
        #expect(isContinuation("It reports progress (see the plan)", "one outcome."))
        // A capital starts a new sentence.
        #expect(!isContinuation("It reports progress at each", "One outcome."))
        // A new item is never a continuation.
        #expect(!isContinuation("It reports progress at each", "• one outcome."))
        #expect(!isContinuation("It reports progress at each", "- one outcome."))
        #expect(!isContinuation("It reports progress at each", "1. one outcome."))
        #expect(!isContinuation("It reports progress at each", "2) one outcome."))
        // Nothing to compare against.
        #expect(!isContinuation("", "one outcome."))
        #expect(!isContinuation("It reports progress", ""))
    }
}
