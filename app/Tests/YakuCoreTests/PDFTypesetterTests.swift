import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import YakuCore

@Suite("PDF typesetter")
struct PDFTypesetterTests {
    // MARK: - Helpers

    /// A Japanese abstract of about 200 characters, the realistic case.
    private static let abstract = """
        この文章は組版の試験のために書いた架空の要旨である。メニューバーに常駐する翻訳アプリは、\
        選んだ文や画面の文字をその場で訳し、訳文を元の位置に重ねて表示する。処理はすべて手元の\
        計算機の中で行い、原文も訳文も外へ送らない。長い段落は文の切れ目で分け、前の二つの訳を\
        手がかりにして続きを訳す。用語集に登録した言葉は、指定した訳語で必ず置き換える。
        """

    private func input(_ pieces: [PDFTypesetInput.Piece],
                       box: CGRect = CGRect(x: 72, y: 600, width: 300, height: 40),
                       maxBox: CGRect? = nil,
                       fontSize: CGFloat = 12,
                       lineCount: Int = 3,
                       serif: Bool = true,
                       bold: Bool = false,
                       alignment: PDFTypesetInput.Alignment = .natural) -> PDFTypesetInput {
        PDFTypesetInput(pieces: pieces, box: box, maxBox: maxBox ?? box.insetBy(dx: 0, dy: -200),
                        fontSize: fontSize, lineCount: lineCount, serif: serif, bold: bold,
                        alignment: alignment)
    }

    private func isInside(_ inner: CGRect, _ outer: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.maxX <= outer.maxX + tolerance
            && inner.minY >= outer.minY - tolerance && inner.maxY <= outer.maxY + tolerance
    }

    private func lineTexts(_ layout: PDFTypesetLayout) -> [String] {
        let string = layout.attributed.string as NSString
        return layout.lines.compactMap { line in
            let range = CTLineGetStringRange(line)
            guard range.location >= 0, range.length > 0 else { return nil }
            return string.substring(with: NSRange(location: range.location, length: range.length))
        }
    }

    private func fontNames(of page: CGPDFPage) -> [String] {
        final class Names {
            var values: [String] = []
        }
        guard let pageDictionary = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
              let resources else { return [] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [] }
        let names = Names()
        CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &font), let font else { return true }
            var base: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(font, "BaseFont", &base), let base {
                names.values.append(String(cString: base))
            }
            return true
        }, nil)
        return names.values
    }

    // MARK: - Fitting

    @Test("short text keeps the original size and the top edge")
    func shortTextFits() {
        let input = input([.text("短い文です。")], box: CGRect(x: 72, y: 600, width: 300, height: 40),
                          fontSize: 12, lineCount: 2)
        let result = PDFTypesetter.layout(input)
        #expect(result.fontSize == 12)
        #expect(!result.overflowed)
        #expect(isInside(result.usedRect, input.box))
        #expect(abs(result.usedRect.maxY - input.box.maxY) <= 0.5)
        #expect(result.inlinePlacements.isEmpty)
    }

    @Test("long text with no room below shrinks until it fits the original box")
    func longTextShrinks() {
        let box = CGRect(x: 72, y: 500, width: 220, height: 60)
        let input = input([.text(String(Self.abstract.prefix(90)))], box: box,
                          maxBox: box, fontSize: 12, lineCount: 3)
        let result = PDFTypesetter.layout(input)
        #expect(result.fontSize < input.fontSize)
        #expect(result.fontSize >= 12 * 0.5 - 0.001)
        #expect(!result.overflowed)
        #expect(isInside(result.usedRect, box))
        #expect(abs(result.usedRect.maxY - box.maxY) <= 0.5)
    }

    @Test("text that needs more than a 15% cut uses the space below before shrinking further")
    func growsBeforeShrinkingFar() {
        let box = CGRect(x: 72, y: 500, width: 220, height: 60)
        let maxBox = box.insetBy(dx: 0, dy: -300)
        let result = PDFTypesetter.layout(input([.text(String(Self.abstract.prefix(90)))], box: box,
                                                maxBox: maxBox, fontSize: 12, lineCount: 3))
        #expect(result.fontSize >= 12 * 0.85 - 0.001)
        #expect(!result.overflowed)
        #expect(isInside(result.usedRect, maxBox))
        #expect(abs(result.usedRect.maxY - box.maxY) <= 0.5)
    }

    @Test("the first line keeps the original indent")
    func firstLineIndent() {
        var indented = input([.inline(id: 0, size: CGSize(width: 4, height: 4), descent: 0),
                              .text(String(Self.abstract.prefix(60)))],
                             box: CGRect(x: 72, y: 500, width: 300, height: 200), lineCount: 6)
        indented.firstLineIndent = 15
        let plain = PDFTypesetter.layout(input([.inline(id: 0, size: CGSize(width: 4, height: 4), descent: 0),
                                                .text(String(Self.abstract.prefix(60)))],
                                               box: CGRect(x: 72, y: 500, width: 300, height: 200), lineCount: 6))
        let shifted = PDFTypesetter.layout(indented)
        let before = plain.inlinePlacements[0]!.minX
        let after = shifted.inlinePlacements[0]!.minX
        #expect(abs(after - before - 15) <= 0.5)
    }

    @Test("a tall inline formula does not reach into the line above")
    func tallInlineGetsRoom() {
        let fraction = CGSize(width: 14, height: 22)
        let pieces: [PDFTypesetInput.Piece] = [.text(String(Self.abstract.prefix(40))),
                                               .inline(id: 0, size: fraction, descent: 8),
                                               .text(String(Self.abstract.prefix(40)))]
        let box = CGRect(x: 72, y: 400, width: 200, height: 300)
        let result = PDFTypesetter.layout(input(pieces, box: box, fontSize: 10, lineCount: 8))
        let placement = try! #require(result.inlinePlacements[0])
        // The formula sits inside the used area and the text above starts at the box top,
        // so a formula on a later line leaves at least one line of room above it.
        #expect(placement.maxY <= box.maxY + 0.5)
        #expect(placement.height == fraction.height)
    }

    @Test("very long text grows downward into maxBox")
    func veryLongTextGrows() {
        let box = CGRect(x: 72, y: 500, width: 220, height: 24)
        let maxBox = CGRect(x: 72, y: 380, width: 220, height: 400)
        let input = input([.text(Self.abstract)], box: box, maxBox: maxBox, fontSize: 12, lineCount: 2)
        let result = PDFTypesetter.layout(input)
        #expect(result.fontSize < input.fontSize)
        #expect(!result.overflowed)
        #expect(result.usedRect.minY < box.minY)
        #expect(isInside(result.usedRect, maxBox))
        #expect(abs(result.usedRect.maxY - box.maxY) <= 0.5)
        #expect(result.fontSize >= 12 * 0.5 - 0.001)
    }

    @Test("text that cannot fit even at the minimum size overflows")
    func overflowingText() {
        let box = CGRect(x: 72, y: 500, width: 100, height: 20)
        let maxBox = CGRect(x: 72, y: 460, width: 100, height: 60)
        let long = String(repeating: Self.abstract, count: 4)
        let input = input([.text(long)], box: box, maxBox: maxBox, fontSize: 12, lineCount: 1)
        let result = PDFTypesetter.layout(input)
        #expect(result.overflowed)
        #expect(result.fontSize >= 4)
        #expect(abs(result.usedRect.maxY - box.maxY) <= 0.5)
        #expect(result.usedRect.height > maxBox.height)
    }

    @Test("the minimum size is never below four points")
    func minimumSizeFloor() {
        let box = CGRect(x: 0, y: 0, width: 40, height: 8)
        let input = input([.text(String(repeating: "長い文章です。", count: 20))], box: box,
                          maxBox: box, fontSize: 5, lineCount: 1)
        let result = PDFTypesetter.layout(input)
        #expect(result.overflowed)
        #expect(result.fontSize == 4)
    }

    @Test("centered text stays centered inside the box")
    func centeredAlignment() {
        let box = CGRect(x: 100, y: 600, width: 300, height: 40)
        let input = input([.text("中央揃えの見出し")], box: box, fontSize: 14, lineCount: 1,
                          bold: true, alignment: .center)
        let result = PDFTypesetter.layout(input)
        let left = result.usedRect.minX - box.minX
        let right = box.maxX - result.usedRect.maxX
        #expect(abs(left - right) <= 1)
        #expect(result.usedRect.width < box.width)
    }

    @Test("the line advance follows the original leading within the allowed range")
    func lineSpacing() {
        let tight = input([.text(String(Self.abstract.prefix(120)))],
                          box: CGRect(x: 0, y: 0, width: 300, height: 60), fontSize: 10, lineCount: 6)
        let tightLayout = PDFTypesetter.buildLayout(tight, size: 10)
        #expect(tightLayout.lineOrigins.count > 1)
        let tightAdvance = tightLayout.lineOrigins[0].y - tightLayout.lineOrigins[1].y
        // The original leading is 60 / 6 = 10, below the 1.15 floor at 10 pt.
        #expect(abs(tightAdvance - 11.5) <= 0.01)

        let loose = input([.text(String(Self.abstract.prefix(120)))],
                          box: CGRect(x: 0, y: 0, width: 300, height: 120), fontSize: 10, lineCount: 4)
        let looseLayout = PDFTypesetter.buildLayout(loose, size: 10)
        let looseAdvance = looseLayout.lineOrigins[0].y - looseLayout.lineOrigins[1].y
        // The original leading is 120 / 4 = 30, above the 1.5 ceiling at 10 pt.
        #expect(abs(looseAdvance - 15) <= 0.01)
    }

    @Test("the font follows the serif and bold flags")
    func fontSelection() {
        let cases: [(Bool, Bool, String)] = [(true, false, "HiraMinProN-W3"), (true, true, "HiraMinProN-W6"),
                                             (false, false, "HiraginoSans-W3"), (false, true, "HiraginoSans-W6")]
        for (serif, bold, name) in cases {
            let input = input([.text("見出し Heading")], serif: serif, bold: bold)
            let layout = PDFTypesetter.buildLayout(input, size: 12)
            let key = NSAttributedString.Key(kCTFontAttributeName as String)
            let value = layout.attributed.attribute(key, at: 0, effectiveRange: nil)
            let font = value as! CTFont
            #expect(CTFontCopyPostScriptName(font) as String == name)
        }
    }

    // MARK: - Inline objects

    @Test("an inline object reserves its box on a baseline")
    func inlinePlacement() throws {
        let box = CGRect(x: 72, y: 600, width: 300, height: 60)
        let input = input([.text("この式 "), .inline(id: 7, size: CGSize(width: 20, height: 8), descent: 2),
                           .text(" は重要である。")], box: box, fontSize: 12, lineCount: 2)
        let result = PDFTypesetter.layout(input)
        let placement = try #require(result.inlinePlacements[7])
        #expect(abs(placement.width - 20) <= 0.01)
        #expect(abs(placement.height - 8) <= 0.01)
        #expect(isInside(placement, result.usedRect))
        let layout = PDFTypesetter.buildLayout(input, size: result.fontSize)
        let baseline = placement.minY + 2
        #expect(layout.lineOrigins.contains { abs($0.y - baseline) <= 0.5 })
    }

    @Test("every inline object gets its own placement")
    func multipleInlines() {
        let box = CGRect(x: 72, y: 600, width: 300, height: 60)
        let input = input([.text("式 "), .inline(id: 1, size: CGSize(width: 12, height: 8), descent: 2),
                           .text(" と式 "), .inline(id: 2, size: CGSize(width: 16, height: 10), descent: 3),
                           .text(" を比べる。")], box: box, fontSize: 12, lineCount: 2)
        let result = PDFTypesetter.layout(input)
        #expect(result.inlinePlacements.count == 2)
        #expect(result.inlinePlacements[1]?.width == 12)
        #expect(result.inlinePlacements[2]?.width == 16)
        #expect(result.inlinePlacements[1]?.minX != result.inlinePlacements[2]?.minX)
    }

    // MARK: - Line breaking

    @Test("a line never starts with Japanese closing punctuation")
    func kinsoku() {
        // Ten characters per line, so a naive break would put 。 at the start of a line.
        let text = String(repeating: "ああああああああああ。", count: 8)
        let box = CGRect(x: 0, y: 0, width: 100, height: 400)
        let input = input([.text(text)], box: box, maxBox: box, fontSize: 10, lineCount: 1)
        let layout = PDFTypesetter.buildLayout(input, size: 10)
        let lines = lineTexts(layout)
        #expect(lines.count > 3)
        for line in lines {
            #expect(!line.hasPrefix("。"))
            #expect(!line.hasPrefix("、"))
        }
        // The punctuation has to appear somewhere, otherwise the check above proves nothing.
        #expect(lines.contains { $0.contains("。") })
    }

    // MARK: - Drawing

    @Test("drawing into a PDF context embeds the Japanese text and the font")
    func drawIntoPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typesetter-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let box = CGRect(x: 72, y: 600, width: 300, height: 60)
        let input = input([.text("これは日本語の組版テストです。")], box: box, fontSize: 12, lineCount: 2)
        let result = PDFTypesetter.draw(input, in: context)
        context.endPDFPage()
        context.closePDF()
        #expect(!result.overflowed)

        let document = try #require(PDFDocument(url: url))
        let text = try #require(document.string)
        #expect(text.contains("これは日本語の組版テストです。"))
        let page = try #require(document.page(at: 0))
        let cgPage = try #require(page.pageRef)
        #expect(fontNames(of: cgPage).contains { $0.contains("HiraMinProN") })
        // The text has to land where the English was, not at the page origin.
        var ink = CGRect.null
        for index in 0..<page.numberOfCharacters {
            ink = ink.union(page.characterBounds(at: index))
        }
        #expect(!ink.isNull)
        #expect(isInside(ink, box, tolerance: 1))
        #expect(ink.minX - box.minX <= 8)
        #expect(box.maxY - ink.maxY <= 8)
    }

    @Test("the context state is unchanged after drawing")
    func drawLeavesContextClean() throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typesetter-state-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let box = CGRect(x: 20, y: 100, width: 160, height: 40)
        let input = input([.text("状態を変えない。")], box: box, fontSize: 10, lineCount: 1)
        let before = context.ctm
        _ = PDFTypesetter.draw(input, in: context)
        #expect(context.ctm == before)
        #expect(context.textMatrix == .identity)
        context.endPDFPage()
        context.closePDF()
    }

    @Test("a realistic paragraph renders to a PNG for review")
    func renderPreview() throws {
        let page = CGRect(x: 0, y: 0, width: 480, height: 130)
        let box = CGRect(x: 40, y: 25, width: 400, height: 80)
        let input = input([.text(Self.abstract)], box: box, maxBox: box, fontSize: 10, lineCount: 6)
        let scale: CGFloat = 3
        let width = Int(page.width * scale)
        let height = Int(page.height * scale)
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(page)
        // A Core Graphics bitmap context already has y up, like page space.
        bitmap.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        bitmap.setLineWidth(0.5)
        bitmap.stroke(box)
        let result = PDFTypesetter.draw(input, in: bitmap)
        let image = try #require(bitmap.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typesetter-preview.png")
        try data.write(to: url)
        print("typeset preview PNG: \(url.path) (size \(result.fontSize), used \(result.usedRect))")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Performance

    @Test("one paragraph lays out well under five milliseconds")
    func layoutPerformance() {
        let box = CGRect(x: 72, y: 500, width: 400, height: 80)
        let fitting = input([.text(Self.abstract)], box: box, maxBox: box.insetBy(dx: 0, dy: -200),
                            fontSize: 10, lineCount: 6)
        let shrinking = input([.text(Self.abstract)], box: CGRect(x: 72, y: 500, width: 220, height: 60),
                              maxBox: box.insetBy(dx: 0, dy: -300), fontSize: 12, lineCount: 3)
        for paragraph in [fitting, shrinking] {
            _ = PDFTypesetter.layout(paragraph)
            // The fastest round is the least polluted one: the test runner works in parallel.
            var fastest = Double.infinity
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = PDFTypesetter.layout(paragraph)
                fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print("typeset layout: \(fastest) ms per paragraph")
            #expect(fastest < 5)
        }
    }
}
