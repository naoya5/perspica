import CoreGraphics
import Foundation
import Testing
@testable import YakuCore

@Suite("Overlay text sizing")
struct OverlayFitTests {
    @Test("the font size follows the original line height")
    func originalFontSize() {
        // A 20pt line is drawn at about 16.7pt.
        #expect(abs(OverlayTextFit.originalFontSize(forLineHeight: 20) - 20 / 1.2) < 0.001)
        // A tiny line is not drawn below the floor.
        #expect(OverlayTextFit.originalFontSize(forLineHeight: 2) == OverlayTextFit.minimumFontSize)
    }

    @Test("text that already fits keeps the original size")
    func fitsAtFullSize() {
        let layout = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 300, height: 10),
            originalFontSize: 16,
            measure: { _, _, _ in 5 }
        )
        #expect(layout.scale == 1.0)
        #expect(layout.fontSize == 16)
        #expect(layout.overflow == 0)
        #expect(layout.textHeight == 5)
        #expect(layout.width == 300)
    }

    @Test("text that does not fit is stepped down until it does")
    func shrinksToFit() {
        // The height is twice the font size, so a 15pt block needs about 0.75.
        let layout = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 300, height: 15),
            originalFontSize: 10,
            measure: { _, _, size in size * 2 }
        )
        #expect(layout.scale <= 0.76)
        #expect(layout.scale >= 0.74)
        #expect(layout.textHeight <= 15)
        #expect(layout.overflow == 0)
    }

    @Test("text that never fits stops at the minimum and spills over")
    func overflows() {
        let layout = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 300, height: 5),
            originalFontSize: 10,
            measure: { _, _, size in size * 2 }
        )
        #expect(abs(layout.scale - 0.7) < 0.001)
        #expect(abs(layout.fontSize - 7) < 0.001)
        #expect(layout.overflow > 0)
        #expect(abs(layout.textHeight - 14) < 0.001)
    }

    @Test("the minimum scale is the one the settings carry")
    func customMinimum() {
        let layout = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 300, height: 12),
            originalFontSize: 10,
            minimumScale: 0.5,
            measure: { _, _, size in size * 2 }
        )
        // 0.6 would give 12 exactly; anything above that is too tall.
        #expect(layout.scale <= 0.61)
        #expect(layout.scale >= 0.59)
    }

    @Test("a minimum above 1 is clamped, so the text never grows")
    func clampedMinimum() {
        let layout = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 300, height: 100),
            originalFontSize: 10,
            minimumScale: 2.0,
            measure: { _, _, size in size }
        )
        #expect(layout.scale == 1.0)
    }

    @Test("a wider block needs less shrinking")
    func widerBlockFitsBetter() {
        let measure: (String, CGFloat, CGFloat) -> CGFloat = { _, width, size in size * 1000 / width }
        let wide = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 1000, height: 20),
            originalFontSize: 20,
            measure: measure
        )
        let narrow = OverlayTextFit.layout(
            text: "text",
            blockSize: CGSize(width: 200, height: 20),
            originalFontSize: 20,
            measure: measure
        )
        #expect(wide.scale == 1.0)
        #expect(narrow.scale < wide.scale)
    }

    @Test("the defaults match the specification")
    func constants() {
        #expect(OverlayTextFit.defaultMinimumScale == 0.7)
        #expect(OverlayTextFit.scaleStep == 0.05)
    }

    // MARK: one-line blocks grow before they shrink (SPEC 4.6 の 3)

    /// A measure like a real one: one line at `size`, and one more line per
    /// `width / size` characters' worth of text.
    private static func textLike(_ text: String) -> (String, CGFloat, CGFloat) -> CGFloat {
        { piece, width, size in
            let perLine = max(1, Int(width / (size * 0.6)))
            let lines = max(1, (piece.count + perLine - 1) / perLine)
            return CGFloat(lines) * size * 1.2
        }
    }

    @Test("a one-line block grows to the right instead of wrapping")
    func growsBeforeWrapping() {
        // 10 characters at 12pt need 72pt; the box is 40pt, and there is room to
        // 200pt, so the text stays at full size on one line.
        let layout = OverlayTextFit.layout(
            text: String(repeating: "あ", count: 10),
            blockSize: CGSize(width: 40, height: 14),
            originalFontSize: 12,
            widenTo: 200,
            measure: Self.textLike(String(repeating: "あ", count: 10))
        )
        #expect(layout.scale == 1.0)
        #expect(layout.fontSize == 12)
        #expect(layout.overflow == 0)
        #expect(layout.width > 40)
        #expect(layout.width <= 200)
        // One line: 12 × 1.2, not two.
        #expect(abs(layout.textHeight - 14.4) < 0.001)
    }

    @Test("a one-line block with no room still shrinks")
    func noRoomStillShrinks() {
        let layout = OverlayTextFit.layout(
            text: String(repeating: "あ", count: 10),
            blockSize: CGSize(width: 40, height: 14),
            originalFontSize: 12,
            widenTo: 50,
            measure: Self.textLike(String(repeating: "あ", count: 10))
        )
        #expect(layout.scale < 1.0)
    }

    @Test("a block of several lines keeps its own width")
    func multiLineKeepsItsWidth() {
        let layout = OverlayTextFit.layout(
            text: String(repeating: "あ", count: 40),
            blockSize: CGSize(width: 100, height: 60),
            originalFontSize: 12,
            widenTo: nil,
            measure: Self.textLike(String(repeating: "あ", count: 40))
        )
        #expect(layout.width == 100)
    }

    @Test("the wrap moves the break rather than stranding ー at the line start")
    func kinsoku() {
        // `プライバシー` in a box too narrow for it even at 70%: 6 characters at
        // 12pt need 43pt, and the floor gives 8.4pt, so 5 fit in the 42pt
        // limit and the sixth (ー) would start the second line.
        let text = "プライバシー"
        let measure = Self.textLike(text)
        let size: CGFloat = 12
        let height = size * 1.2
        let limit: CGFloat = 42
        // What the plain greedy break gives: 5 characters, then ー.
        #expect(OverlayTextFit.firstLineCount(text, width: limit, size: size, height: height, measure: measure) == 5)
        let width = OverlayTextFit.legalWrapWidth(
            text, upTo: limit, atLeast: 20, size: size, height: height, measure: measure)
        #expect(width < limit)
        let count = OverlayTextFit.firstLineCount(text, width: width, size: size, height: height, measure: measure)
        #expect(count == 4)
        let next = text[text.index(text.startIndex, offsetBy: count)]
        #expect(!OverlayTextFit.isLineStartForbidden(next))
    }

    @Test("a legal wrap is left alone")
    func kinsokuLeavesLegalAlone() {
        let text = "プライバシー"
        let measure = Self.textLike(text)
        let size: CGFloat = 12
        let height = size * 1.2
        // Four characters fit, so the fifth (シ) starts line two: already legal.
        let width = OverlayTextFit.legalWrapWidth(
            text, upTo: 34, atLeast: 20, size: size, height: height, measure: measure)
        #expect(width == 34)
    }

    @Test("the wrap never comes back narrower than the block")
    func kinsokuKeepsTheBlockWidth() {
        // The backing is drawn at the returned width, so a narrower one would
        // leave the original text showing at the sides. `プライバシー` in a box
        // narrower than the legal break needs: the wrap stays at the box.
        let text = "プライバシー"
        let measure = Self.textLike(text)
        let size: CGFloat = 12
        let height = size * 1.2
        let width = OverlayTextFit.legalWrapWidth(
            text, upTo: 42, atLeast: 42, size: size, height: height, measure: measure)
        #expect(width == 42)
        // And through `layout`, the returned width is never below the block's.
        let layout = OverlayTextFit.layout(
            text: text,
            blockSize: CGSize(width: 42, height: height),
            originalFontSize: size,
            widenTo: 42,
            measure: measure
        )
        #expect(layout.width >= 42)
    }

    @Test("the forbidden set covers the prolonged mark, small kana and punctuation")
    func forbiddenSet() {
        for character in ["ー", "っ", "ゃ", "、", "。", "」", "）", "！"] as [Character] {
            #expect(OverlayTextFit.isLineStartForbidden(character), "\(character)")
        }
        for character in ["あ", "ア", "A", "1"] as [Character] {
            #expect(!OverlayTextFit.isLineStartForbidden(character), "\(character)")
        }
    }
}

@Suite("Overlay block context")
struct OverlayContextTests {
    @Test("the other blocks are used, and the block itself is left out")
    func otherBlocks() {
        let context = OverlayContext.context(forIndex: 1, in: ["Alpha.", "Beta.", "Gamma."])
        #expect(context == "Alpha. Gamma.")
    }

    @Test("the context stops at the limit")
    func limited() {
        let texts = ["0123456789", "abcdefghij", "ABCDEFGHIJ"]
        let context = OverlayContext.context(forIndex: 0, in: texts, limit: 12)
        #expect(context.count == 12)
        #expect(context == "abcdefghij A")
    }

    @Test("blank blocks are skipped")
    func blanksSkipped() {
        let context = OverlayContext.context(forIndex: 0, in: ["First.", "   ", "Third."])
        #expect(context == "Third.")
    }

    @Test("a single block has no context")
    func singleBlock() {
        #expect(OverlayContext.context(forIndex: 0, in: ["Only."]) == "")
    }

    @Test("the specification's ceiling is 600 characters")
    func limitConstant() {
        #expect(OverlayContext.limit == 600)
    }
}
