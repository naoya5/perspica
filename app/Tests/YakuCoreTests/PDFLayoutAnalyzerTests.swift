import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import YakuCore

@Suite("PDF layout analysis")
struct PDFLayoutAnalyzerTests {
    // MARK: - Synthetic page builder

    static let body = PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                   isMath: false, isMonospace: false)
    static let bold = PDFFontStyle(isSerif: true, isBold: true, isItalic: false,
                                   isMath: false, isMonospace: false)
    static let math = PDFFontStyle(isSerif: true, isBold: false, isItalic: true,
                                   isMath: true, isMonospace: false)
    static let mono = PDFFontStyle(isSerif: false, isBold: false, isItalic: false,
                                   isMath: false, isMonospace: true)

    /// Builds glyphs with a fixed advance per character, which is all the layout
    /// analyzer needs to see lines, gaps and words.
    private struct Page {
        var glyphs: [PDFGlyph] = []
        var graphics: [PDFGraphic] = []
        var hints: [CGRect] = []
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var op = 0

        /// Appends one run of text; returns the x just after it.
        @discardableResult
        mutating func run(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 10,
                          style: PDFFontStyle = PDFLayoutAnalyzerTests.body,
                          advance: CGFloat? = nil, renderMode: Int = 0) -> CGFloat {
            let step = advance ?? size * 0.5
            var cursor = x
            for character in text {
                glyphs.append(PDFGlyph(unicode: String(character), origin: CGPoint(x: cursor, y: y),
                                       advance: step, fontSize: size, fontName: "F1", style: style,
                                       opIndex: op, renderMode: renderMode))
                cursor += step
            }
            op += 1
            return cursor
        }

        func paragraphs() -> [PDFParagraph] {
            PDFLayoutAnalyzer.paragraphs(glyphs: glyphs, graphics: graphics, pageBox: box, hints: hints)
        }
    }

    private func text(_ paragraph: PDFParagraph) -> String {
        paragraph.segments.reduce(into: "") { result, segment in
            switch segment {
            case .text(let value): result += value
            case .formula(let value, _, _): result += value
            }
        }
    }

    // MARK: - Single column

    @Test("one column splits into paragraphs on spacing and first-line indent")
    func singleColumnParagraphs() {
        var page = Page()
        page.run("Lorem ipsum dolor sit amet consectetur adipiscing elit sed", x: 72, y: 700)
        page.run("do eiusmod tempor incididunt ut labore et dolore magna aliqua", x: 72, y: 688)
        page.run("ut enim ad minim veniam quis nostrud exercitation ullamco", x: 72, y: 676)
        page.run("Duis aute irure dolor in reprehenderit in voluptate velit", x: 72, y: 648)
        page.run("esse cillum dolore eu fugiat nulla pariatur excepteur sint", x: 72, y: 636)
        page.run("Occaecat cupidatat non proident sunt in culpa qui officia", x: 84, y: 608)
        page.run("deserunt mollit anim id est laborum sed perspiciatis unde", x: 72, y: 596)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs.allSatisfy { $0.role == .body })
        #expect(paragraphs.allSatisfy { $0.translate })
        #expect(paragraphs.map { $0.lineBounds.count } == [3, 2, 2])
        #expect(text(paragraphs[0]).hasPrefix("Lorem ipsum dolor sit amet"))
        #expect(text(paragraphs[0]).hasSuffix("exercitation ullamco"))
        #expect(text(paragraphs[2]).hasPrefix("Occaecat cupidatat"))
    }

    @Test("words are separated when the PDF has no space glyphs")
    func spacesFromGaps() {
        var page = Page()
        page.run("alpha", x: 72, y: 700)
        page.run("beta", x: 72 + 5 * 5 + 4, y: 700)
        page.run("gamma", x: 72 + 5 * 5 + 4 + 4 * 5 + 4, y: 700)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(text(paragraphs[0]) == "alpha beta gamma")
    }

    @Test("a word broken across lines is joined without the hyphen")
    func hyphenJoin() {
        var page = Page()
        page.run("The transformer uses a trans-", x: 72, y: 700)
        page.run("duction model for translation", x: 72, y: 688)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(text(paragraphs[0]) == "The transformer uses a transduction model for translation")
    }

    // MARK: - Columns

    @Test("two columns are read left to right under a full-width title")
    func twoColumnsWithTitle() {
        var page = Page()
        page.run("A Full Width Title That Spans Both Columns Of This Page", x: 72, y: 740, size: 16)
        page.run("Left column first paragraph line one", x: 72, y: 700)
        page.run("left column first paragraph line two", x: 72, y: 688)
        page.run("Left column second paragraph line one", x: 72, y: 660)
        page.run("Right column first paragraph line one", x: 320, y: 700)
        page.run("right column first paragraph line two", x: 320, y: 688)
        page.run("Right column second paragraph line one", x: 320, y: 660)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.map { String(text($0).prefix(18)) } == [
            "A Full Width Title",
            "Left column first ",
            "Left column second",
            "Right column first",
            "Right column second",
        ].map { String($0.prefix(18)) })
        // The title is above both columns, so it is read first.
        if paragraphs.count > 1 {
            #expect(paragraphs[0].bounds.minY > paragraphs[1].bounds.minY)
        }
    }

    /// Lines of one column all end at the same x, the way justified text does.
    /// Every line of these fixtures is 45 characters, so a column is 180 pt wide.
    private static let leftColumn = [
        "Left column first line of the paragraph here",
        "left column second line of the paragraph here",
        "left column third line ends the paragraph now",
    ]
    private static let rightColumn = [
        "Right column first line of the paragraph here",
        "right column second line of the paragraph here",
        "right column third line ends the paragraph now",
    ]

    /// Two columns of three lines that share their baselines, with a 24 pt
    /// gutter between them: the layout of a two-column paper.
    private func twoColumnPage() -> Page {
        var page = Page()
        for (offset, line) in Self.leftColumn.enumerated() {
            page.run(line, x: 72, y: 700 - CGFloat(offset) * 12, advance: 4)
        }
        for (offset, line) in Self.rightColumn.enumerated() {
            page.run(line, x: 276, y: 700 - CGFloat(offset) * 12, advance: 4)
        }
        return page
    }

    @Test("two columns that share baselines are read left then right")
    func twoColumnsSharedBaselines() {
        let paragraphs = twoColumnPage().paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs.map { $0.lineBounds.count } == [3, 3])
        #expect(text(paragraphs[0]).hasPrefix("Left column first line"))
        #expect(text(paragraphs[0]).hasSuffix("ends the paragraph now"))
        #expect(text(paragraphs[1]).hasPrefix("Right column first line"))
        #expect(text(paragraphs[1]).hasSuffix("ends the paragraph now"))
        // The left column is 72-252 and the right one starts at 276: no block
        // reaches across the gutter.
        #expect(paragraphs[0].bounds.maxX <= 252.5)
        #expect(paragraphs[1].bounds.minX >= 275.5)
    }

    @Test("a full-width title above two columns stays whole")
    func fullWidthTitleAboveColumns() {
        var page = twoColumnPage()
        page.run("A Full Width Title That Spans Both Columns Of This Page", x: 72, y: 720,
                 size: 16, advance: 6)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[0].lineBounds.count == 1)
        #expect(text(paragraphs[0]) == "A Full Width Title That Spans Both Columns Of This Page")
        #expect(paragraphs[0].bounds.minX < 200)
        #expect(paragraphs[0].bounds.maxX > 300)
        // The title is read first, then the whole left column, then the right one.
        #expect(text(paragraphs[1]).hasPrefix("Left column"))
        #expect(text(paragraphs[2]).hasPrefix("Right column"))
    }

    @Test("a full-width caption below the columns is read after both of them")
    func fullWidthCaptionBelowColumns() {
        var page = twoColumnPage()
        page.run("Figure 1. A full width caption that sits below both columns.", x: 72, y: 640,
                 advance: 4)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(text(paragraphs[0]).hasPrefix("Left column"))
        #expect(text(paragraphs[1]).hasPrefix("Right column"))
        #expect(paragraphs[2].role == .caption)
        #expect(paragraphs[2].lineBounds.count == 1)
        #expect(paragraphs[2].bounds.maxX > 300)
    }

    @Test("a caption at the top of the right column stays in that column")
    func captionInRightColumn() {
        var page = twoColumnPage()
        page.run("Figure 1. Training error and test error on the dataset.", x: 276, y: 720, size: 9)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(text(paragraphs[0]).hasPrefix("Left column"))
        #expect(paragraphs[1].role == .caption)
        #expect(text(paragraphs[1]).hasPrefix("Figure 1."))
        #expect(paragraphs[1].bounds.minX >= 275.5)
        #expect(text(paragraphs[2]).hasPrefix("Right column"))
    }

    @Test("a table whose cells line up in two blocks does not split the page")
    func tableCellsDoNotSplitThePage() {
        var page = Page()
        // Four rows of two cells: the left cells end at 252, the right ones
        // start at 276, so the edges are shared the way a gutter's are.
        for offset in 0..<4 {
            page.run("Layer type number one of the model table here", x: 72,
                     y: 700 - CGFloat(offset) * 12, advance: 4)
            page.run("Complexity per layer of the model table here", x: 276,
                     y: 700 - CGFloat(offset) * 12, advance: 4)
        }
        // Prose below the table runs across the whole text area.
        for offset in 0..<6 {
            page.run("The prose below the table explains what the numbers mean here", x: 72,
                     y: 600 - CGFloat(offset) * 12, advance: 4)
        }

        let paragraphs = page.paragraphs()
        let prose = paragraphs.filter { text($0).hasPrefix("The prose below") }
        #expect(prose.count == 1)
        #expect(prose.first?.lineBounds.count == 6)
        #expect(prose.first?.bounds.maxX ?? 0 > 300)
    }

    // MARK: - Formulas

    @Test("an inline formula keeps its subscript as one segment")
    func inlineFormula() {
        var page = Page()
        var x = page.run("where d", x: 72, y: 700)
        x = page.run("d", x: x, y: 700, style: Self.math)
        x = page.run("k", x: x, y: 698, size: 7, style: Self.math)
        page.run(" is the dimension of the model", x: x, y: 700)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[0].segments.count == 3)
        guard case .text(let first) = paragraphs[0].segments[0] else {
            Issue.record("expected leading text")
            return
        }
        #expect(first == "where d")
        guard case .formula(let formula, let bounds, let baseline) = paragraphs[0].segments[1] else {
            Issue.record("expected a formula segment")
            return
        }
        #expect(formula == "dk")
        #expect(abs(baseline - 700) < 0.001)
        #expect(bounds.minX >= 107)
        #expect(bounds.width < 12)
        guard case .text(let last) = paragraphs[0].segments[2] else {
            Issue.record("expected trailing text")
            return
        }
        #expect(last == " is the dimension of the model")
    }

    @Test("a centred display formula takes its equation number and is not translated")
    func displayFormulaWithNumber() {
        var page = Page()
        page.run("The attention function is computed for every query in the batch of", x: 72, y: 700)
        page.run("queries and keys at once as described in the section that comes above.", x: 72, y: 688)
        page.run("Attention(Q, K, V) = softmax(QKT) V", x: 214.5, y: 660)
        page.run("(1)", x: 500, y: 660)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[1].role == .formula)
        #expect(paragraphs[1].translate == false)
        // The formula line plus the equation number: every glyph of the block.
        #expect(paragraphs[1].glyphIndices.count == "Attention(Q, K, V) = softmax(QKT) V".count + 3)
        #expect(text(paragraphs[1]).hasSuffix("(1)"))
        guard case .formula(_, let bounds, let baseline) = paragraphs[1].segments.first else {
            Issue.record("a formula paragraph is one formula segment")
            return
        }
        #expect(abs(baseline - 660) < 0.001)
        #expect(bounds.minX < 220)
    }

    @Test("a mostly math line is a formula even when it is not centred")
    func leftAlignedFormula() {
        var page = Page()
        page.run("and the result follows directly from the definition above", x: 72, y: 700)
        page.run("x + y = z", x: 72, y: 660, style: Self.math)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[1].role == .formula)
        #expect(paragraphs[1].translate == false)
    }

    // MARK: - Roles

    @Test("a page number in the bottom margin is furniture")
    func pageNumber() {
        var page = Page()
        page.run("Body text that sits in the middle of the page for the test", x: 72, y: 400)
        page.run("7", x: 300, y: 20)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[1].role == .pageFurniture)
        #expect(paragraphs[1].translate == false)
    }

    @Test("a running head at the top margin is furniture and a URL is not translated")
    func runningHeadAndLink() {
        var page = Page()
        page.run("Perspica Technical Report", x: 72, y: 770)
        page.run("Body text in the middle of the page that should be translated.", x: 72, y: 400)
        page.run("https://example.com/paper", x: 72, y: 380)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].role == .pageFurniture)
        #expect(paragraphs[0].translate == false)
        #expect(paragraphs[1].role == .body)
        #expect(paragraphs[1].translate)
        #expect(paragraphs[2].role == .other)
        #expect(paragraphs[2].translate == false)
    }

    @Test("a figure caption is translated")
    func caption() {
        var page = Page()
        page.run("Figure 3: The encoder and decoder stacks with their sublayers.", x: 72, y: 500)
        page.run("The arrows show the flow of data through the model.", x: 72, y: 488)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].role == .caption)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[0].lineBounds.count == 2)
    }

    @Test("text inside a figure region is not translated")
    func figureRegion() {
        var page = Page()
        for offset in stride(from: 0, to: 200, by: 40) {
            page.graphics.append(PDFGraphic(kind: .path,
                                            bounds: CGRect(x: 100 + offset, y: 300, width: 60, height: 120)))
        }
        page.run("Encoder", x: 120, y: 400)
        page.run("Decoder", x: 250, y: 400)
        page.run("Text below the figure belongs to the body of the paper.", x: 72, y: 200)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].role == .other)
        #expect(paragraphs[0].translate == false)
        #expect(paragraphs[1].role == .other)
        #expect(paragraphs[2].role == .body)
        #expect(paragraphs[2].translate)
    }

    @Test("list items start their own paragraphs")
    func listItems() {
        var page = Page()
        page.run("• First item of the list that wraps onto", x: 72, y: 700)
        page.run("a second line of the same item here", x: 72, y: 688)
        page.run("• Second item of the list", x: 72, y: 676)
        page.run("1. Numbered item in the same list", x: 72, y: 664)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs.allSatisfy { $0.role == .listItem })
        #expect(paragraphs.allSatisfy { $0.translate })
        #expect(paragraphs[0].lineBounds.count == 2)
    }

    @Test("a bold short line followed by body text is a heading")
    func heading() {
        var page = Page()
        page.run("Introduction", x: 72, y: 700, size: 14, style: Self.bold)
        page.run("This paragraph follows the heading and is set in the body size.", x: 72, y: 680)
        page.run("It continues on a second line with more words to fill it out.", x: 72, y: 668)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .heading)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[1].role == .body)
    }

    @Test("a numbered section line is a heading without a size change")
    func numberedHeading() {
        var page = Page()
        page.run("3.2.1 Scaled Dot-Product Attention", x: 72, y: 700)
        page.run("We call our particular attention scaled dot-product attention.", x: 72, y: 680)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .heading)
    }

    @Test("monospace code and bare numbers are not translated")
    func codeAndNumbers() {
        var page = Page()
        page.run("let value = compute(input)", x: 72, y: 700, style: Self.mono)
        page.run("42.5", x: 72, y: 660)
        page.run("Ordinary prose that should be translated for the reader.", x: 72, y: 620)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].role == .other)
        #expect(paragraphs[0].translate == false)
        #expect(paragraphs[1].role == .other)
        #expect(paragraphs[1].translate == false)
        #expect(paragraphs[2].translate)
    }

    @Test("many small figure labels do not change the body size")
    func smallLabelsKeepBodySize() {
        var page = Page()
        // Twenty-four short labels in 5 pt (two per row, as in a network diagram)
        // outnumber the five lines of 10 pt prose.
        for row in 0..<12 {
            for column in 0..<2 {
                page.run("conv 64", x: 72 + CGFloat(column) * 120, y: 728 - CGFloat(row) * 8, size: 5)
            }
        }
        page.run("Our plain baselines are mainly inspired by the philosophy of the", x: 72, y: 600)
        page.run("VGG nets in which the convolutional layers mostly have small filters", x: 72, y: 588)
        page.run("and follow two simple design rules for the same output feature map", x: 72, y: 576)
        page.run("size where the layers have the same number of filters and the map", x: 72, y: 564)
        page.run("size is halved to keep the time complexity per layer.", x: 72, y: 552)
        let prose = page.paragraphs().filter { text($0).contains("plain baselines") }
        #expect(prose.count == 1)
        #expect(prose.first?.role == .body)
        #expect(prose.first?.lineBounds.count == 5)
    }

    @Test("a full line that starts with a number continues its paragraph")
    func lineStartingWithNumber() {
        var page = Page()
        page.run("ImageNet test set and won the first place in the ILSVRC contest", x: 72, y: 700)
        page.run("2015 classification competition and the extremely deep models", x: 72, y: 688)
        page.run("also have excellent generalization performance on other tasks", x: 72, y: 676)
        page.run("such as detection and segmentation.", x: 72, y: 664)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs.first?.role == .body)
    }

    @Test("a bold run-in heading stays in its paragraph")
    func runInHeading() {
        var page = Page()
        // Most of the first line is bold, but only its start is the heading.
        let end = page.run("Residual Representations and Encodings.", x: 72, y: 700, style: Self.bold)
        page.run(" In image recognition VLAD", x: end, y: 700)
        page.run("that encodes by the residual vectors with respect to a dictionary", x: 72, y: 688)
        page.run("and the Fisher Vector can be formulated as a probabilistic version", x: 72, y: 676)
        page.run("of the same representation.", x: 72, y: 664)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs.first?.role == .body)
    }

    @Test("a line that starts with Fig. inside a paragraph is not a caption")
    func figureReferenceAtLineStart() {
        var page = Page()
        page.run("Based on the above plain network we insert shortcut connections (see", x: 72, y: 700)
        page.run("Fig. 3) which turn the network into its counterpart residual version", x: 72, y: 688)
        page.run("and the identity shortcuts can be directly used when the input and", x: 72, y: 676)
        page.run("output are of the same dimensions.", x: 72, y: 664)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs.first?.role == .body)
    }

    @Test("two labels side by side at nearby baselines stay apart")
    func labelsSideBySide() {
        var page = Page()
        page.run("weight layer", x: 98, y: 680, size: 9)
        page.run("identity", x: 215, y: 675, size: 9)
        #expect(page.paragraphs().count == 2)
    }

    @Test("a short label set smaller than the body is not translated")
    func smallLabel() {
        var page = Page()
        page.run("34-layer plain", x: 150, y: 720, size: 8)
        page.run("The plain baselines are mainly inspired by the philosophy of", x: 72, y: 680)
        page.run("the VGG nets and the convolutional layers mostly have small filters", x: 72, y: 668)
        let paragraphs = page.paragraphs()
        let label = paragraphs.first { text($0) == "34-layer plain" }
        #expect(label?.role == .other)
        #expect(label?.translate == false)
        #expect(paragraphs.contains { text($0).hasPrefix("The plain baselines") && $0.translate })
    }

    @Test("a big operator hanging near the line above joins its operand's line")
    func hangingSummation() {
        var page = Page()
        page.run("assume the components of q and k are independent random vars", x: 72, y: 700)
        page.run("Then q·k = ", x: 72, y: 688)
        // TeX hangs the sign from a point nearer the line above than its own line.
        page.run("∑", x: 128.5, y: 697, style: Self.math, advance: 6)
        page.run("qk, has mean zero and variance as large as the dimension", x: 135, y: 688)
        let all = page.paragraphs().map(text).joined(separator: " | ")
        #expect(all.contains("components of"))
        #expect(all.contains("∑"))
    }

    @Test("a grid of short cells is a table and is not translated")
    func table() {
        var page = Page()
        page.run("Name", x: 72, y: 700)
        page.run("Value", x: 200, y: 700)
        page.run("Unit", x: 320, y: 700)
        page.run("alpha", x: 72, y: 688)
        page.run("1.5", x: 200, y: 688)
        page.run("mm", x: 320, y: 688)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        guard paragraphs.count == 1 else { return }
        #expect(paragraphs[0].role == .other)
        #expect(paragraphs[0].translate == false)
        #expect(paragraphs[0].lineBounds.count == 2)
    }

    @Test("a missing media box falls back to the glyph extent")
    func missingPageBox() {
        var page = Page()
        page.run("Text on a page without a media box still forms a paragraph.", x: 72, y: 700)
        page.run("It continues on a second line of the same paragraph here.", x: 72, y: 688)
        let paragraphs = PDFLayoutAnalyzer.paragraphs(glyphs: page.glyphs, graphics: [], pageBox: .zero)
        #expect(paragraphs.count == 1)
        #expect(paragraphs.first?.role == .body)
    }

    @Test("small text at the bottom of the page is a footnote")
    func footnote() {
        var page = Page()
        page.run("The body of the page runs here with normal sized glyphs.", x: 72, y: 400)
        page.run("It continues on a second line set in the same body size.", x: 72, y: 388)
        page.run("1 A footnote set in a smaller size at the bottom of the page.", x: 72, y: 90, size: 7)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs.count == 2)
        guard paragraphs.count == 2 else { return }
        #expect(paragraphs[1].role == .footnote)
        #expect(paragraphs[1].translate)
    }

    // MARK: - Hints and visibility

    @Test("hint boxes break paragraphs and are optional")
    func hints() {
        var page = Page()
        page.run("First sentence of the block that continues here", x: 72, y: 700)
        page.run("and ends on the second line of the block", x: 72, y: 688)
        page.run("Second block starts on its own line here", x: 72, y: 676)

        #expect(page.paragraphs().count == 1)
        page.hints = [CGRect(x: 72, y: 684, width: 250, height: 24),
                      CGRect(x: 72, y: 672, width: 250, height: 12)]
        #expect(page.paragraphs().count == 2)
    }

    @Test("invisible glyphs are ignored")
    func invisibleGlyphs() {
        var page = Page()
        page.run("Visible text on the line", x: 72, y: 700)
        page.run("Hidden overlay text", x: 72, y: 688, renderMode: 3)
        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(text(paragraphs[0]) == "Visible text on the line")
        #expect(paragraphs[0].glyphIndices.count == 24)
    }

    @Test("every visible glyph belongs to exactly one paragraph")
    func glyphCoverage() {
        var page = Page()
        page.run("A Full Width Title That Spans Both Columns Of This Page", x: 72, y: 740, size: 16)
        page.run("Left column first paragraph line one", x: 72, y: 700)
        page.run("left column first paragraph line two", x: 72, y: 688)
        page.run("Right column first paragraph line one", x: 320, y: 700)
        page.run("Attention(Q, K, V) = softmax(QKT) V", x: 214.5, y: 660)
        page.run("(1)", x: 500, y: 660)
        page.run("7", x: 300, y: 20)

        let paragraphs = page.paragraphs()
        let assigned = paragraphs.flatMap(\.glyphIndices)
        #expect(Set(assigned).count == assigned.count)
        // Every glyph on this page is visible, so every index must be placed.
        #expect(Set(assigned) == Set(page.glyphs.indices))
        #expect(paragraphs.allSatisfy { !$0.lineBounds.isEmpty })
    }

    @Test("an empty page has no paragraphs")
    func emptyPage() {
        #expect(PDFLayoutAnalyzer.paragraphs(glyphs: [], graphics: [], pageBox: .zero).isEmpty)
    }

    // MARK: - Fixture

    /// PDFKit gives us characters and boxes long before the real interpreter
    /// exists. `characterBounds(at:)` returns per-glyph ink boxes that are
    /// inconsistent for the math runs of this fixture (some glyphs land on the
    /// wrong baseline, a few at the origin), so the helper prefers PDFKit's
    /// per-character selection box, which is a line-height box, and falls back to
    /// `characterBounds(at:)` when no selection is available.
    private static func pdfKitGlyphs(pageIndex: Int) -> (glyphs: [PDFGlyph], box: CGRect)? {
        guard let url = fixtureURL, let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex), let string = page.string else { return nil }
        var glyphs: [PDFGlyph] = []
        for (offset, character) in Array(string).enumerated() {
            let selection = page.selection(for: NSRange(location: offset, length: 1))?.bounds(for: page)
            let characterBox = page.characterBounds(at: offset)
            let box = [selection, characterBox]
                .compactMap { $0 }
                .first { $0.width > 0.1 && $0.height > 0.1 }
            guard let box else { continue }
            let size = box.height
            let style = PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                     isMath: isMathCharacter(character), isMonospace: false)
            glyphs.append(PDFGlyph(unicode: String(character),
                                   origin: CGPoint(x: box.minX, y: box.minY + 0.22 * size),
                                   advance: box.width, fontSize: size, fontName: "PDFKit",
                                   style: style, opIndex: 0, renderMode: 0))
        }
        return (glyphs, page.bounds(for: .mediaBox))
    }

    private static func isMathCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0370...0x03FF, 0x2190...0x21FF, 0x2200...0x22FF, 0x27C0...0x27FF,
             0x2900...0x297F, 0x2A00...0x2AFF:
            return true
        default:
            break
        }
        return "=±×÷".unicodeScalars.contains(scalar)
    }

    private static var fixtureURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("fixtures/attention.pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static var resnetURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("fixtures/resnet.pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The gutter of this paper is at x=286...309. A line is on the left when it
    /// ends before the gutter and on the right when it starts after it.
    private func column(of box: CGRect) -> Int {
        if box.maxX <= 290 { return -1 }
        if box.minX >= 306 { return 1 }
        return 0
    }

    @Test("resnet.pdf never joins the lines of the two columns")
    func resnetFixtureColumns() {
        guard let url = Self.resnetURL, let document = CGPDFDocument(url as CFURL) else {
            print("skipping: fixtures/resnet.pdf is not available")
            return
        }
        for index in 0..<min(6, document.numberOfPages) {
            guard let page = document.page(at: index + 1) else { continue }
            let paragraphs = NativePDFTranslator.analyze(page, index: index).paragraphs
            #expect(!paragraphs.isEmpty)
            for paragraph in paragraphs {
                let sides = Set(paragraph.lineBounds.map(column(of:)))
                #expect(!(sides.contains(-1) && sides.contains(1)),
                        "page \(index) joins the columns in \(text(paragraph).prefix(40))")
            }
        }
    }

    @Test("resnet.pdf page 0 reads the left column before the right one")
    func resnetFixtureReadingOrder() {
        guard let url = Self.resnetURL, let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            print("skipping: fixtures/resnet.pdf is not available")
            return
        }
        let paragraphs = NativePDFTranslator.analyze(page, index: 0).paragraphs
        // The title and the author block are full-width and come first.
        #expect(paragraphs.first.map { self.text($0).hasPrefix("Deep Residual Learning") } == true)
        // The abstract is one paragraph of the left column, not one per line.
        let abstract = paragraphs.first { self.text($0).hasPrefix("Deeper neural networks") }
        #expect(abstract?.role == .body)
        #expect(abstract?.lineBounds.count == 15)
        #expect(abstract.map { $0.bounds.maxX <= 290 } == true)
        // "1. Introduction" is a heading of the left column.
        let heading = paragraphs.first { self.text($0) == "1. Introduction" }
        #expect(heading?.role == .heading)
        #expect(heading.map { $0.bounds.maxX <= 290 } == true)
        // Figure 1 is at the top of the right column, with its caption, and the
        // caption is read before the body text below it.
        let caption = paragraphs.first { self.text($0).hasPrefix("Figure 1.") }
        #expect(caption?.role == .caption)
        #expect(caption?.lineBounds.count == 4)
        #expect(caption.map { $0.bounds.minX >= 306 } == true)
        let captionIndex = paragraphs.firstIndex { self.text($0).hasPrefix("Figure 1.") }
        let firstRightBody = paragraphs.firstIndex { paragraph in
            paragraph.role == .body && paragraph.bounds.minX >= 306
        }
        if let captionIndex, let firstRightBody {
            #expect(captionIndex < firstRightBody)
        } else {
            Issue.record("expected a caption and body text in the right column")
        }
        // The left column is read before the right one.
        let lastLeft = paragraphs.lastIndex { $0.bounds.maxX <= 290 }
        if let lastLeft, let firstRightBody {
            #expect(lastLeft < firstRightBody)
        }
    }

    @Test("attention.pdf page 4 splits into paragraphs and finds its equation")
    func attentionFixture() {
        guard let (glyphs, box) = Self.pdfKitGlyphs(pageIndex: 3) else {
            print("skipping: fixtures/attention.pdf is not available")
            return
        }
        let paragraphs = PDFLayoutAnalyzer.paragraphs(glyphs: glyphs, graphics: [], pageBox: box)
        for paragraph in paragraphs {
            let head = String(text(paragraph).prefix(60))
            print("\(paragraph.role) translate=\(paragraph.translate) | \(head)")
        }
        #expect((8...40).contains(paragraphs.count))

        let scaled = paragraphs.first { normalized(text($0)).contains("ScaledDot-ProductAttention") }
        #expect(scaled != nil)

        let equation = paragraphs.first {
            $0.role == .formula && normalized(text($0)).contains("Attention(Q,K,V)")
        }
        #expect(equation != nil)
        #expect(equation?.translate == false)
    }
}

// MARK: - Paragraph and formula defects found on the real paper

@Suite("PDF layout defects")
struct PDFLayoutDefectTests {
    private static let body = PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                           isMath: false, isMonospace: false)
    private static let math = PDFFontStyle(isSerif: true, isBold: false, isItalic: true,
                                           isMath: true, isMonospace: false)

    /// Builds glyphs with a fixed advance per character, like the main suite.
    private struct Page {
        var glyphs: [PDFGlyph] = []
        var graphics: [PDFGraphic] = []
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var op = 0

        @discardableResult
        mutating func run(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 10,
                          style: PDFFontStyle = PDFLayoutDefectTests.body,
                          advance: CGFloat? = nil) -> CGFloat {
            let step = advance ?? size * 0.5
            var cursor = x
            for character in text {
                glyphs.append(PDFGlyph(unicode: String(character), origin: CGPoint(x: cursor, y: y),
                                       advance: step, fontSize: size, fontName: "F1", style: style,
                                       opIndex: op, renderMode: 0))
                cursor += step
            }
            op += 1
            return cursor
        }

        func paragraphs() -> [PDFParagraph] {
            PDFLayoutAnalyzer.paragraphs(glyphs: glyphs, graphics: graphics, pageBox: box)
        }
    }

    private func text(_ paragraph: PDFParagraph) -> String {
        paragraph.segments.reduce(into: "") { result, segment in
            switch segment {
            case .text(let value): result += value
            case .formula(let value, _, _): result += value
            }
        }
    }

    @Test("labels and fragments on both sides do not split a single column")
    func figureLabelsDoNotMakeColumns() {
        var page = Page()
        // Two labels side by side at the top of a figure look like column starts.
        page.run("Scaled Dot-Product Attention", x: 120, y: 740)
        page.run("Multi-Head Attention", x: 360, y: 740)
        // A full width line followed by its short last line.
        page.run("The input consists of queries and keys of dimension dk and values", x: 72, y: 600)
        page.run("keys.", x: 72, y: 588)
        // Short lines on the left and formula fragments on the right, at heights
        // that do not interleave, are not two columns.
        page.run("values.", x: 72, y: 548)
        page.run("queries.", x: 72, y: 508)
        page.run("x + y = z", x: 360, y: 560, style: Self.math)
        page.run("a + b = c", x: 360, y: 520, style: Self.math)
        page.run("p + q = r", x: 360, y: 480, style: Self.math)

        let paragraphs = page.paragraphs()
        let block = paragraphs.first { text($0).hasPrefix("The input") }
        #expect(block != nil)
        #expect(block?.lineBounds.count == 2)
        #expect(block.map { text($0).hasSuffix("keys.") } == true)
    }

    @Test("a wrapped caption keeps its short last line and ends there")
    func captionKeepsShortLastLine() {
        var page = Page()
        page.run("Figure 2: (left) Scaled Dot-Product Attention. (right) Multi-Head", x: 72, y: 700)
        page.run("running in parallel.", x: 72, y: 688)
        page.run("We call our particular attention scaled dot-product attention.", x: 72, y: 676)
        page.run("It is used for the encoder and the decoder in this model.", x: 72, y: 664)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .caption)
        #expect(paragraphs[0].lineBounds.count == 2)
        #expect(paragraphs[1].role == .body)
        #expect(paragraphs[1].lineBounds.count == 2)
    }

    @Test("a wrapped heading keeps its short last line")
    func headingKeepsShortLastLine() {
        var page = Page()
        page.run("Provided proper attribution is provided, Google hereby grants permission to", x: 72, y: 700,
                 size: 12)
        page.run("reproduce the tables and figures in this paper solely for use in", x: 72, y: 688, size: 12)
        page.run("scholarly works.", x: 72, y: 676, size: 12)
        page.run("The dominant sequence transduction models are based on complex networks.", x: 72, y: 640)
        page.run("Recurrent neural networks and convolutional networks are used here.", x: 72, y: 628)
        page.run("Attention mechanisms have become an integral part of these models.", x: 72, y: 616)
        page.run("The encoder and the decoder are built from identical layers here.", x: 72, y: 604)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .heading)
        #expect(paragraphs[0].lineBounds.count == 3)
        #expect(text(paragraphs[0]).hasSuffix("scholarly works."))
        #expect(paragraphs[1].role == .body)
    }

    @Test("a vertically stacked display equation becomes one formula")
    func stackedDisplayEquation() {
        var page = Page()
        page.run("In practice, we compute the attention function on a set of queries", x: 72, y: 700)
        page.run("simultaneously, packed together into a matrix Q, and the outputs as:", x: 72, y: 688)
        // A fraction QK^T over sqrt(d_k) above the main line, and "(1)" at the margin.
        page.run("QKT", x: 300, y: 664, style: Self.math)
        page.run("Attention(Q, K, V) = softmax(", x: 220, y: 656, style: Self.math)
        page.run("dk", x: 330, y: 648, size: 7, style: Self.math)
        page.run(") V", x: 350, y: 656, style: Self.math)
        page.run("(1)", x: 500, y: 656)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[1].role == .formula)
        #expect(paragraphs[1].translate == false)
        #expect(paragraphs[1].lineBounds.count == 3)
        #expect(text(paragraphs[1]).contains("QKT"))
        #expect(text(paragraphs[1]).contains("(1)"))
        guard case .formula(_, let bounds, _) = paragraphs[1].segments.first else {
            Issue.record("a formula paragraph is one formula segment")
            return
        }
        #expect(bounds.height > 20)
    }

    @Test("an inline fraction denominator joins the formula of its line")
    func inlineFractionDenominator() {
        var page = Page()
        page.run("Dot-product attention is identical to our algorithm, except for", x: 72, y: 700)
        var x = page.run("the scaling factor of 1/", x: 72, y: 688)
        x = page.run("√", x: x, y: 688, size: 7, style: Self.math)
        x = page.run("1", x: x, y: 688, size: 7)
        page.run("dk", x: x - 2, y: 682, size: 7, style: Self.math)
        page.run("and then we apply a softmax function to the result of every query", x: x, y: 688)
        page.run("in the batch before we continue with the rest of the computation.", x: 72, y: 676)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[0].lineBounds.count == 3)
        // The denominator's glyphs are part of the paragraph, not a paragraph.
        #expect(paragraphs[0].glyphIndices.count == page.glyphs.count)
        let formulas = paragraphs[0].segments.compactMap { segment -> CGRect? in
            if case .formula(_, let bounds, _) = segment { return bounds }
            return nil
        }
        #expect(formulas.count == 1)
        #expect(formulas.first.map { $0.minY < 684 } == true)
    }

    @Test("an inline fraction takes its numerator and its bar into the formula")
    func inlineFractionNumerator() {
        var page = Page()
        page.run("Dot-product attention is identical to our algorithm, except for", x: 72, y: 700)
        let start = page.run("the scaling factor of ", x: 72, y: 688)
        // The numerator is a small glyph of the text line, set above the formula
        // and outside its math run, exactly as TeX draws "1 over the square root".
        page.run("1", x: start + 1, y: 691.5, size: 7)
        var x = page.run("√", x: start, y: 688, size: 7, style: Self.math)
        x = page.run("d", x: x, y: 683.5, size: 7, style: Self.math)
        x = page.run("k", x: x, y: 682.5, size: 5, style: Self.math)
        let bar = CGRect(x: 182, y: 689.5, width: 10, height: 0)
        let overbar = CGRect(x: 185.5, y: 690, width: 6, height: 0)
        page.graphics.append(PDFGraphic(kind: .path, bounds: bar))
        page.graphics.append(PDFGraphic(kind: .path, bounds: overbar))
        page.run("and then we apply a softmax function to the result", x: x, y: 688)
        page.run("in the batch before we continue with the rest of the computation.", x: 72, y: 676)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].role == .body)
        // The numerator is drawn once, inside the formula, and not again as text.
        #expect(paragraphs[0].glyphIndices.count == page.glyphs.count)
        let formulas = paragraphs[0].segments.compactMap { segment -> (String, CGRect)? in
            if case .formula(let value, let bounds, _) = segment { return (value, bounds) }
            return nil
        }
        #expect(formulas.count == 1)
        #expect(formulas.first?.0 == "1/√dk")
        #expect(text(paragraphs[0]).contains("the scaling factor of 1/√dk and then"))
        guard let bounds = formulas.first?.1 else { return }
        // The box covers the numerator and the bar, so the formula is drawn whole
        // and the bar is removed from its old place.
        #expect(bounds.maxY >= 696.9)
        #expect(bounds.contains(bar))
        #expect(bounds.contains(overbar))
    }

    @Test("a short last line stays with the paragraph above across a run split")
    func shortLastLineAcrossRuns() {
        var page = Page()
        // Four rows of two cells share their edges, so the column finder sees a
        // gutter at x=252...276 in the middle of the page.
        for offset in 0..<4 {
            page.run("Layer type number one of the model table here", x: 72,
                     y: 700 - CGFloat(offset) * 12, advance: 4)
            page.run("Complexity per layer of the model table here", x: 276,
                     y: 700 - CGFloat(offset) * 12, advance: 4)
        }
        // The next paragraph starts full width and ends with a short last line,
        // which the reading order puts in a run of its own.
        page.run("The prose below the table explains what the numbers mean here", x: 72, y: 640,
                 advance: 4)
        page.run("and it ends here.", x: 72, y: 628, advance: 4)

        // The reading order really does split the two lines into different runs:
        // the full-width line crosses the gutter and the short line does not.
        let lines = PDFLayoutGlyphs.lines(from: PDFLayoutGlyphs.prepare(page.glyphs))
        let tables = PDFLayoutTables.regions(lines: lines, graphics: page.graphics, pageBox: page.box)
        let figures = PDFLayoutFigures.regions(graphics: page.graphics, pageBox: page.box)
        let gutter = PDFLayoutColumns.gutter(lines: lines, tables: tables, figures: figures)
        #expect(gutter != nil)
        let runs = PDFLayoutColumns.readingOrder(lines: lines, gutter: gutter)
        let first = runs.firstIndex { run in run.contains { lines[$0].text.hasPrefix("The prose below") } }
        let last = runs.firstIndex { run in run.contains { lines[$0].text.hasPrefix("and it ends") } }
        #expect(first != nil)
        #expect(first != last)

        let paragraphs = page.paragraphs()
        let block = paragraphs.first { text($0).hasPrefix("The prose below") }
        #expect(block?.role == .body)
        #expect(block?.lineBounds.count == 2)
        #expect(block.map { text($0).hasSuffix("and it ends here.") } == true)
    }

    // MARK: - Tables

    @Test("a table between horizontal rules is not translated")
    func ruledTable() {
        var page = Page()
        page.run("Table 2: The model reaches a better score than the baselines.", x: 72, y: 710)
        for y in stride(from: 620, through: 680, by: 20) {
            page.graphics.append(PDFGraphic(kind: .path,
                                            bounds: CGRect(x: 72, y: CGFloat(y), width: 468, height: 0)))
        }
        page.run("Model", x: 80, y: 670)
        page.run("BLEU", x: 300, y: 670)
        page.run("Cost", x: 420, y: 670)
        page.run("alpha", x: 80, y: 650)
        page.run("1.5", x: 300, y: 650)
        page.run("2.0", x: 420, y: 650)
        page.run("beta", x: 80, y: 630)
        page.run("2.5", x: 300, y: 630)
        page.run("3.0", x: 420, y: 630)
        page.run("The body of the page continues below the table with prose.", x: 72, y: 560)
        page.run("It goes on for a second line so that the column is measured.", x: 72, y: 548)

        let paragraphs = page.paragraphs()
        let caption = paragraphs.first { text($0).hasPrefix("Table 2") }
        #expect(caption?.role == .caption)
        #expect(caption?.translate == true)
        let cells = paragraphs.filter { $0.bounds.maxY <= 681 && $0.bounds.minY >= 619 }
        #expect(!cells.isEmpty)
        #expect(cells.allSatisfy { $0.role == .other && $0.translate == false })
        let body = paragraphs.first { text($0).hasPrefix("The body of the page") }
        #expect(body?.role == .body)
        #expect(body?.translate == true)
    }

    @Test("a block of rows that share column starts is a table")
    func gridTable() {
        var page = Page()
        page.run("Item", x: 72, y: 700)
        page.run("1.5", x: 200, y: 700)
        page.run("2.0", x: 300, y: 700)
        page.run("Other", x: 72, y: 688)
        page.run("2.5", x: 200, y: 688)
        page.run("3.0", x: 300, y: 688)
        page.run("Third", x: 72, y: 676)
        page.run("3.5", x: 200, y: 676)
        page.run("4.0", x: 300, y: 676)
        page.run("The prose below the table explains what the numbers mean.", x: 72, y: 620)
        page.run("It continues on a second line of the same paragraph here.", x: 72, y: 608)

        let paragraphs = page.paragraphs()
        let cells = paragraphs.filter { $0.bounds.minY >= 673 }
        #expect(!cells.isEmpty)
        #expect(cells.allSatisfy { $0.role == .other && $0.translate == false })
        let body = paragraphs.first { text($0).hasPrefix("The prose below") }
        #expect(body?.role == .body)
        #expect(body?.translate == true)
    }

    @Test("two columns of prose are not a table")
    func twoColumnsAreNotATable() {
        var page = Page()
        let left = ["Left column text of the first paragraph here",
                    "and its second line continues the sentence",
                    "and the third line ends the paragraph"]
        let right = ["Right column text of the first paragraph",
                     "and its second line continues the sentence",
                     "and the third line ends the paragraph"]
        for (offset, line) in left.enumerated() {
            page.run(line, x: 72, y: 700 - CGFloat(offset) * 12)
        }
        for (offset, line) in right.enumerated() {
            page.run(line, x: 320, y: 700 - CGFloat(offset) * 12)
        }
        let paragraphs = page.paragraphs()
        #expect(!paragraphs.isEmpty)
        #expect(paragraphs.allSatisfy { $0.role != .other })
    }

    // MARK: - Rows of scripts

    @Test("a row of superscripts over several formula chunks joins the paragraph")
    func superscriptRowOverFormulaChunks() {
        var page = Page()
        page.run("Where the projections are parameter matrices", x: 72, y: 700)
        page.run("Wi∈R", x: 320, y: 700, style: Self.math)
        page.run("Wi∈R", x: 362, y: 700, style: Self.math)
        page.run("Wi∈R", x: 404, y: 700, style: Self.math)
        page.run("Qdmodel×dkKdmodel×dkVdmodel×dv", x: 335, y: 704, size: 5, style: Self.math)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[0].lineBounds.count == 4)
        // The 5 pt row is not a paragraph of its own: every glyph is in the block.
        #expect(paragraphs[0].glyphIndices.count == page.glyphs.count)
        let formulas = paragraphs[0].segments.filter { segment in
            if case .formula = segment { return true }
            return false
        }
        #expect(formulas.count == 3)
        #expect(text(paragraphs[0]).hasPrefix("Where the projections are parameter matrices"))
    }

    // MARK: - Author block

    @Test("the author block between the title and the abstract is not translated")
    func authorBlock() {
        var page = Page()
        page.run("Attention Is All You Need", x: 180, y: 700, size: 17)
        page.run("Ashish Vaswani Noam Shazeer Niki Parmar", x: 140, y: 660)
        page.run("Google Brain Google Research", x: 150, y: 648)
        page.run("avaswani@google.com noam@google.com", x: 140, y: 636)
        page.run("Abstract", x: 280, y: 600, size: 12)
        page.run("The dominant sequence transduction models are based on complex recurrent", x: 72, y: 580)
        page.run("or convolutional neural networks that include an encoder and a decoder.", x: 72, y: 568)

        let paragraphs = page.paragraphs()
        let title = paragraphs.first { text($0) == "Attention Is All You Need" }
        #expect(title?.role == .heading)
        #expect(title?.translate == true)
        let heading = paragraphs.first { text($0) == "Abstract" }
        #expect(heading?.role == .heading)
        #expect(heading?.translate == true)
        let body = paragraphs.first { text($0).hasPrefix("The dominant sequence") }
        #expect(body?.role == .body)
        #expect(body?.translate == true)
        // Everything between the title and the abstract is the author block.
        let block = paragraphs.filter { paragraph in
            paragraph.bounds.maxY <= (title?.bounds.minY ?? 0)
                && paragraph.bounds.minY >= (heading?.bounds.maxY ?? 0)
        }
        #expect(!block.isEmpty)
        #expect(block.allSatisfy { $0.role == .other && $0.translate == false })
        #expect(block.flatMap(\.lineBounds).count == 3)
    }

    // MARK: - Footnote marks

    @Test("a mark before a footnote stays its own untranslated paragraph")
    func footnoteMarkBeforeFootnote() {
        var page = Page()
        page.run("The body of the page runs here with normal sized glyphs.", x: 72, y: 400)
        page.run("It continues on a second line set in the same body size.", x: 72, y: 388)
        page.run("1", x: 84, y: 96, size: 6)
        page.run("A footnote set in a smaller size at the bottom of the page.", x: 88, y: 92, size: 9)

        let paragraphs = page.paragraphs()
        let mark = paragraphs.first { text($0) == "1" }
        #expect(mark?.role == .other)
        #expect(mark?.translate == false)
        let note = paragraphs.first { text($0).hasPrefix("A footnote") }
        #expect(note?.role == .footnote)
        #expect(note?.translate == true)
    }

    @Test("a mark inside body text stays in its paragraph as a formula")
    func footnoteMarkInsideBody() {
        var page = Page()
        var x = page.run("The capacity of each GPU", x: 72, y: 400)
        x = page.run("5", x: x, y: 404, size: 6)
        page.run(" is enough for the work described here.", x: x, y: 400)

        let paragraphs = page.paragraphs()
        #expect(paragraphs.count == 1)
        guard paragraphs.count == 1 else { return }
        #expect(paragraphs[0].role == .body)
        #expect(paragraphs[0].translate)
        #expect(paragraphs[0].glyphIndices.count == page.glyphs.count)
        let formulas = paragraphs[0].segments.filter { segment in
            if case .formula = segment { return true }
            return false
        }
        #expect(formulas.count == 1)
        guard case .formula(let mark, _, _) = formulas.first else {
            Issue.record("expected a formula segment for the mark")
            return
        }
        #expect(mark == "5")
    }
}
