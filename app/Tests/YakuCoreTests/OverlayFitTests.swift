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
            blockSize: CGSize(width: 300, height: 10),
            originalFontSize: 16,
            measure: { _, _ in 5 }
        )
        #expect(layout.scale == 1.0)
        #expect(layout.fontSize == 16)
        #expect(layout.overflow == 0)
        #expect(layout.textHeight == 5)
    }

    @Test("text that does not fit is stepped down until it does")
    func shrinksToFit() {
        // The height is twice the font size, so a 15pt block needs about 0.75.
        let layout = OverlayTextFit.layout(
            blockSize: CGSize(width: 300, height: 15),
            originalFontSize: 10,
            measure: { _, size in size * 2 }
        )
        #expect(layout.scale <= 0.76)
        #expect(layout.scale >= 0.74)
        #expect(layout.textHeight <= 15)
        #expect(layout.overflow == 0)
    }

    @Test("text that never fits stops at the minimum and spills over")
    func overflows() {
        let layout = OverlayTextFit.layout(
            blockSize: CGSize(width: 300, height: 5),
            originalFontSize: 10,
            measure: { _, size in size * 2 }
        )
        #expect(abs(layout.scale - 0.7) < 0.001)
        #expect(abs(layout.fontSize - 7) < 0.001)
        #expect(layout.overflow > 0)
        #expect(abs(layout.textHeight - 14) < 0.001)
    }

    @Test("the minimum scale is the one the settings carry")
    func customMinimum() {
        let layout = OverlayTextFit.layout(
            blockSize: CGSize(width: 300, height: 12),
            originalFontSize: 10,
            minimumScale: 0.5,
            measure: { _, size in size * 2 }
        )
        // 0.6 would give 12 exactly; anything above that is too tall.
        #expect(layout.scale <= 0.61)
        #expect(layout.scale >= 0.59)
    }

    @Test("a minimum above 1 is clamped, so the text never grows")
    func clampedMinimum() {
        let layout = OverlayTextFit.layout(
            blockSize: CGSize(width: 300, height: 100),
            originalFontSize: 10,
            minimumScale: 2.0,
            measure: { _, size in size }
        )
        #expect(layout.scale == 1.0)
    }

    @Test("a wider block needs less shrinking")
    func widerBlockFitsBetter() {
        let measure: (CGFloat, CGFloat) -> CGFloat = { width, size in size * 1000 / width }
        let wide = OverlayTextFit.layout(
            blockSize: CGSize(width: 1000, height: 20),
            originalFontSize: 20,
            measure: measure
        )
        let narrow = OverlayTextFit.layout(
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
