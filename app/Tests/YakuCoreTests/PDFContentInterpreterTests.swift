import CoreGraphics
import Foundation
import Testing
@testable import YakuCore

/// A decoder with fixed widths, standing in for the real font work.
private struct StubFont: PDFCharDecoding {
    var fontName = "Stub"
    var width: CGFloat = 0.5
    var style = PDFFontStyle(isSerif: false, isBold: false, isItalic: false, isMath: false, isMonospace: false)

    func decode(_ bytes: [UInt8]) -> [PDFDecodedChar] {
        bytes.map {
            PDFDecodedChar(code: Int($0), unicode: String(UnicodeScalar($0)), width: width, isWordSpace: $0 == 32)
        }
    }
}

private let stubFonts: [String: any PDFCharDecoding] = ["F1": StubFont()]

/// Resolves form names from a fixed table.
private struct StubResolver: PDFFormResolving {
    var forms: [String: PDFFormSource]

    func form(named name: String) -> PDFFormSource? { forms[name] }
}

/// Counts resolutions, to show that a form drawn twice is looked up twice.
private final class CountingResolver: PDFFormResolving {
    let forms: [String: PDFFormSource]
    private(set) var calls = 0

    init(forms: [String: PDFFormSource]) { self.forms = forms }

    func form(named name: String) -> PDFFormSource? {
        calls += 1
        return forms[name]
    }
}

/// A resolver whose only form draws itself.
private final class CycleResolver: PDFFormResolving {
    var source: PDFFormSource?

    func form(named name: String) -> PDFFormSource? { source }
}

private func interpret(_ content: String,
                       fonts: [String: any PDFCharDecoding] = stubFonts,
                       xobjectKinds: [String: PDFGraphic.Kind] = [:]) -> PDFPageContent {
    PDFContentInterpreter.interpret(Array(content.utf8), fonts: fonts, xobjectKinds: xobjectKinds)
}

private func lex(_ content: String) -> [PDFContentToken] {
    lex(Array(content.utf8))
}

private func lex(_ bytes: [UInt8]) -> [PDFContentToken] {
    var lexer = PDFContentLexer(bytes)
    var tokens: [PDFContentToken] = []
    while let token = lexer.next() { tokens.append(token) }
    return tokens
}

@Suite("PDFContentInterpreterTests")
struct PDFContentInterpreterTests {
    // MARK: - Lexer

    @Test("numbers, names, booleans, null, brackets and operators are recognized")
    func tokenKinds() {
        let content = "42 -3.5 .25 +7 /Name /A#20B true false null [ ] << >> Tj TJ ' \""
        #expect(lex(content).map(\.kind) == [
            .number(42), .number(-3.5), .number(0.25), .number(7),
            .name("Name"), .name("A B"),
            .boolean(true), .boolean(false), .null,
            .arrayStart, .arrayEnd, .dictionaryStart, .dictionaryEnd,
            .op("Tj"), .op("TJ"), .op("'"), .op("\""),
        ])
    }

    @Test("tokens carry their byte offsets")
    func tokenOffsets() {
        let tokens = lex("  /F1 10 Tf")
        #expect(tokens.map(\.start) == [2, 6, 9])
        #expect(tokens.map(\.end) == [5, 8, 11])
    }

    @Test("literal strings decode every escape")
    func literalStringEscapes() {
        let content = "(a\\(b\\)c\\n\\t\\b\\f\\r\\\\\\101\\0053\\z)"
        let expected: [UInt8] = Array("a(b)c".utf8)
            + [0x0A, 0x09, 0x08, 0x0C, 0x0D, 0x5C, 0x41, 0x05, 0x33, 0x7A]
        #expect(lex(content).map(\.kind) == [.string(expected)])
    }

    @Test("literal strings keep balanced parentheses and survive an unclosed one")
    func literalStringParens() {
        #expect(lex("(a(b(c))d)").map(\.kind) == [.string(Array("a(b(c))d".utf8))])
        #expect(lex("(abc").map(\.kind) == [.string(Array("abc".utf8))])
    }

    @Test("a backslash before an end of line continues the string")
    func lineContinuation() {
        #expect(lex("(one\\\ntwo)").map(\.kind) == [.string(Array("onetwo".utf8))])
        #expect(lex("(one\\\r\ntwo)").map(\.kind) == [.string(Array("onetwo".utf8))])
    }

    @Test("hex strings ignore whitespace and pad an odd digit count")
    func hexStrings() {
        #expect(lex("<48656C6C6F>").map(\.kind) == [.string(Array("Hello".utf8))])
        #expect(lex("<48 65 6C 6C 6F>").map(\.kind) == [.string(Array("Hello".utf8))])
        // 11 digits: the last nibble 7 becomes 0x70.
        #expect(lex("<48656C6C6F7>").map(\.kind) == [.string(Array("Hellop".utf8))])
        #expect(lex("<>").map(\.kind) == [.string([])])
    }

    @Test("comments run to the end of the line")
    func comments() {
        let tokens = lex("1 % a comment\n2 % another\r3")
        #expect(tokens.map(\.kind) == [.number(1), .number(2), .number(3)])
    }

    @Test("an inline image is one token and EI inside the data does not end it")
    func inlineImage() {
        var bytes = Array("BI /W 4 /H 1 /BPC 8 /CS /G ID ".utf8)
        // "AEIB" holds EI without whitespace before it, "x EIy" holds EI
        // without whitespace after it. Neither ends the image.
        bytes += Array("AEIBx EIy".utf8)
        bytes += Array(" EI Q".utf8)

        let tokens = lex(bytes)
        #expect(tokens.count == 2)
        #expect(tokens[0].kind == .inlineImage([
            "W": .number(4),
            "H": .number(1),
            "BPC": .number(8),
            "CS": .name("G"),
        ]))
        #expect(tokens[0].start == 0)
        let imageBytes = String(decoding: bytes[tokens[0].start..<tokens[0].end], as: UTF8.self)
        #expect(imageBytes.hasSuffix("EI"))
        #expect(tokens[1].kind == .op("Q"))
    }

    // MARK: - Interpreter: text positioning

    @Test("Td places the first glyph and advances by the width")
    func textPositioning() {
        let page = interpret("BT /F1 10 Tf 100 700 Td (AB) Tj ET")
        #expect(page.glyphs.count == 2)
        #expect(page.glyphs[0].origin == CGPoint(x: 100, y: 700))
        #expect(page.glyphs[0].advance == 5)
        #expect(page.glyphs[0].fontSize == 10)
        #expect(page.glyphs[1].origin == CGPoint(x: 105, y: 700))
    }

    @Test("TD sets the leading and T* uses it")
    func textLeading() {
        let page = interpret("BT /F1 10 Tf 100 700 Td 0 -14 TD (A) Tj T* (B) Tj ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 100, y: 686))
        #expect(page.glyphs[1].origin == CGPoint(x: 100, y: 672))
    }

    @Test("Tm sets the text matrix directly")
    func textMatrix() {
        let page = interpret("BT /F1 10 Tf 1 0 0 1 50 60 Tm (A) Tj ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 50, y: 60))
    }

    @Test("cm scales positions, advances and the page-space font size")
    func ctmScaling() {
        let page = interpret("q 2 0 0 2 10 20 cm BT /F1 10 Tf 5 5 Td (A) Tj ET Q")
        #expect(page.glyphs[0].origin == CGPoint(x: 20, y: 30))
        #expect(page.glyphs[0].fontSize == 20)
        #expect(page.glyphs[0].advance == 10)
    }

    @Test("Q restores the CTM and the text state")
    func graphicsStateRestore() {
        let page = interpret("q 2 0 0 2 10 20 cm BT /F1 10 Tf 5 5 Td (A) Tj ET Q BT /F1 10 Tf 5 5 Td (B) Tj ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 20, y: 30))
        #expect(page.glyphs[1].origin == CGPoint(x: 5, y: 5))
        #expect(page.glyphs[1].fontSize == 10)
        #expect(page.glyphs[1].advance == 5)

        let spacing = interpret("BT /F1 10 Tf 5 Tc q 2 Tc (A) Tj Q (B) Tj ET")
        #expect(spacing.glyphs[0].advance == 7)
        #expect(spacing.glyphs[1].advance == 10)
    }

    @Test("TJ numbers move the pen by n/1000 em")
    func tjKerning() {
        let page = interpret("BT /F1 10 Tf 100 700 Td [(A) -500 (B)] TJ ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 100, y: 700))
        #expect(page.glyphs[1].origin == CGPoint(x: 110, y: 700))
    }

    @Test("Tc adds to every advance")
    func characterSpacing() {
        let page = interpret("BT /F1 10 Tf 2 Tc (AB) Tj ET")
        #expect(page.glyphs[0].advance == 7)
        #expect(page.glyphs[1].origin == CGPoint(x: 7, y: 0))
    }

    @Test("Tw applies to single-byte space only")
    func wordSpacing() {
        let page = interpret("BT /F1 10 Tf 3 Tw (A B) Tj ET")
        #expect(page.glyphs.map(\.advance) == [5, 8, 5])
        #expect(page.glyphs[2].origin == CGPoint(x: 13, y: 0))
    }

    @Test("Tz scales the advance but not the font size")
    func horizontalScaling() {
        let page = interpret("BT /F1 10 Tf 50 Tz (AB) Tj ET")
        #expect(page.glyphs[0].advance == 2.5)
        #expect(page.glyphs[0].fontSize == 10)
        #expect(page.glyphs[1].origin == CGPoint(x: 2.5, y: 0))
    }

    @Test("Ts raises the glyph origin")
    func rise() {
        let page = interpret("BT /F1 10 Tf 4 Ts 100 700 Td (A) Tj ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 100, y: 704))
    }

    @Test("the page-space font size follows the text matrix scale")
    func fontSizeFromMatrix() {
        let page = interpret("BT /F1 10 Tf 2 0 0 2 0 0 Tm (A) Tj ET")
        #expect(page.glyphs[0].fontSize == 20)
        #expect(page.glyphs[0].advance == 10)
    }

    @Test("' moves to the next line before showing")
    func quoteOperator() {
        let page = interpret("BT /F1 10 Tf 14 TL 100 700 Td (A) Tj (B) ' ET")
        #expect(page.glyphs[0].origin == CGPoint(x: 100, y: 700))
        #expect(page.glyphs[1].origin == CGPoint(x: 100, y: 686))
    }

    @Test("\" sets word and character spacing, then moves and shows")
    func doubleQuoteOperator() {
        let page = interpret("BT /F1 10 Tf 14 TL 100 700 Td 2 1 (A B) \" ET")
        #expect(page.glyphs.map(\.origin) == [
            CGPoint(x: 100, y: 686),
            CGPoint(x: 106, y: 686),
            CGPoint(x: 114, y: 686),
        ])
        #expect(page.glyphs.map(\.advance) == [6, 8, 6])
    }

    @Test("render mode is carried on the glyph")
    func renderMode() {
        let page = interpret("BT /F1 10 Tf 3 Tr (A) Tj ET")
        #expect(page.glyphs[0].renderMode == 3)
    }

    @Test("show operators keep their byte range and glyph range")
    func showRanges() {
        let content = "BT /F1 10 Tf 100 700 Td (AB) Tj 0 -14 Td (C) Tj ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        #expect(page.showOps.count == 2)
        #expect(page.showOps[0].op == "Tj")
        #expect(String(decoding: bytes[page.showOps[0].byteRange], as: UTF8.self) == "(AB) Tj")
        #expect(page.showOps[0].glyphRange == 0..<2)
        #expect(page.showOps[1].glyphRange == 2..<3)
        #expect(page.glyphs[1].opIndex == 0)
        #expect(page.glyphs[2].opIndex == 1)
    }

    @Test("an unknown font falls back to one byte per code")
    func unknownFont() {
        let page = interpret("BT /Missing 10 Tf (AB) Tj ET")
        #expect(page.glyphs.count == 2)
        #expect(page.glyphs[0].unicode == "")
        #expect(page.glyphs[0].advance == 5)
        #expect(page.glyphs[0].fontName == "Missing")
    }

    // MARK: - Interpreter: graphics

    @Test("paths are reported with page-space bounds")
    func pathGraphics() {
        let page = interpret("q 100 100 50 40 re f Q q 2 0 0 2 0 0 cm 0 0 10 10 re S Q")
        #expect(page.graphics.count == 2)
        #expect(page.graphics[0].kind == .path)
        #expect(page.graphics[0].bounds == CGRect(x: 100, y: 100, width: 50, height: 40))
        #expect(page.graphics[1].bounds == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test("curves and lines contribute to the path box")
    func curveGraphics() {
        let page = interpret("10 10 m 20 20 l 30 40 50 60 70 80 c S")
        #expect(page.graphics.count == 1)
        #expect(page.graphics[0].bounds == CGRect(x: 10, y: 10, width: 60, height: 70))
    }

    @Test("n and degenerate paths are not reported")
    func noPaint() {
        let page = interpret("10 10 m 20 20 l n 10 10 m S")
        #expect(page.graphics.isEmpty)
    }

    @Test("XObjects use the declared kind and the unit square")
    func xobjectGraphics() {
        let page = interpret("/Im1 Do /Im2 Do", xobjectKinds: ["Im1": .form])
        #expect(page.graphics.count == 2)
        #expect(page.graphics[0].kind == .form)
        #expect(page.graphics[0].bounds == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(page.graphics[1].kind == .image)
    }

    @Test("an inline image is reported as an image")
    func inlineImageGraphic() {
        var bytes = Array("q 2 0 0 2 0 0 cm ".utf8)
        bytes += Array("BI /W 1 /H 1 /BPC 8 /CS /G ID ".utf8)
        bytes += [0x00]
        bytes += Array(" EI Q".utf8)
        let page = PDFContentInterpreter.interpret(bytes, fonts: [:])
        #expect(page.graphics.count == 1)
        #expect(page.graphics[0].kind == .image)
        #expect(page.graphics[0].bounds == CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    // MARK: - Forms

    @Test("a form is drawn with its matrix and its own font, and its operators carry its stream")
    func formWithMatrix() {
        let form = PDFFormSource(index: 1,
                                 content: Array("BT /F2 20 Tf 0 0 Td (Hi) Tj ET".utf8),
                                 matrix: CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 100, ty: 200),
                                 fonts: ["F2": StubFont(fontName: "Form", width: 0.25)])
        let page = PDFContentInterpreter.interpret(
            Array("q 2 0 0 2 10 20 cm /Fm1 Do Q".utf8), fonts: stubFonts,
            xobjectKinds: ["Fm1": .form], resolver: StubResolver(forms: ["Fm1": form]))

        // Form space (0, 0) maps through /Matrix to (100, 200), then through the CTM.
        #expect(page.glyphs.map(\.origin) == [CGPoint(x: 210, y: 420), CGPoint(x: 220, y: 420)])
        #expect(page.glyphs.map(\.fontName) == ["Form", "Form"])
        #expect(page.glyphs.map(\.fontSize) == [40, 40])
        #expect(page.showOps.map(\.stream) == [1])
        #expect(page.glyphs.map(\.opIndex) == [0, 0])
        // The form itself is still a graphic of the stream that drew it.
        #expect(page.graphics.map(\.kind) == [.form])
        #expect(page.graphics.map(\.stream) == [0])
    }

    @Test("a form drawn twice keeps one stream index")
    func formDrawnTwice() {
        let form = PDFFormSource(index: 1, content: Array("BT /F1 10 Tf 0 0 Td (A) Tj ET".utf8))
        let resolver = CountingResolver(forms: ["Fm1": form])
        let page = PDFContentInterpreter.interpret(
            Array("/Fm1 Do q 1 0 0 1 0 100 cm /Fm1 Do Q".utf8), fonts: stubFonts,
            xobjectKinds: ["Fm1": .form], resolver: resolver)

        #expect(page.showOps.map(\.stream) == [1, 1])
        #expect(page.glyphs.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)])
        #expect(resolver.calls == 2)
    }

    @Test("a form that draws itself is read once instead of hanging")
    func formCycle() {
        let resolver = CycleResolver()
        resolver.source = PDFFormSource(index: 1,
                                        content: Array("/Fm1 Do BT /F1 10 Tf 0 0 Td (A) Tj ET".utf8),
                                        resolver: resolver)
        let page = PDFContentInterpreter.interpret(Array("/Fm1 Do".utf8), fonts: stubFonts,
                                                   xobjectKinds: ["Fm1": .form], resolver: resolver)

        #expect(page.glyphs.map(\.unicode) == ["A"])
        #expect(page.showOps.map(\.stream) == [1])
    }

    @Test("a form that draws another form gives each its own stream")
    func nestedForm() {
        let inner = PDFFormSource(index: 2, content: Array("BT /F1 10 Tf 0 0 Td (B) Tj ET".utf8))
        let outer = PDFFormSource(index: 1,
                                  content: Array("BT /F1 10 Tf 0 0 Td (A) Tj ET /Fm2 Do".utf8),
                                  xobjectKinds: ["Fm2": .form],
                                  resolver: StubResolver(forms: ["Fm2": inner]))
        let page = PDFContentInterpreter.interpret(Array("/Fm1 Do".utf8), fonts: stubFonts,
                                                   xobjectKinds: ["Fm1": .form],
                                                   resolver: StubResolver(forms: ["Fm1": outer]))

        #expect(page.showOps.map(\.stream) == [1, 2])
        #expect(page.glyphs.map(\.unicode) == ["A", "B"])
    }

    @Test("a form with no resources of its own uses the resources that drew it")
    func formWithoutResources() {
        let form = PDFFormSource(index: 1, content: Array("BT /F1 10 Tf 0 0 Td (A) Tj ET".utf8))
        let page = PDFContentInterpreter.interpret(Array("/Fm1 Do".utf8), fonts: stubFonts,
                                                   xobjectKinds: ["Fm1": .form],
                                                   resolver: StubResolver(forms: ["Fm1": form]))

        #expect(page.glyphs.map(\.unicode) == ["A"])
        #expect(page.glyphs.map(\.fontName) == ["Stub"])
    }

    @Test("malformed operands are ignored instead of crashing")
    func malformedInput() {
        let page = interpret("BT Tj Q Q 1 2 cm 3 Tf (A) Tj ET")
        #expect(page.showOps.count == 2)
        #expect(page.glyphs.count == 1)
        #expect(page.glyphs[0].advance == 1.5)
    }

    // MARK: - Stripper

    @Test("removing an operator inside a form changes only the form's stream")
    func stripFormStream() {
        let streams: [[UInt8]] = [Array("q /Fm1 Do Q".utf8),
                                  Array("BT /F1 10 Tf 0 0 Td (A) Tj ET".utf8)]
        let form = PDFFormSource(index: 1, content: streams[1])
        let page = PDFContentInterpreter.interpret(streams[0], fonts: stubFonts,
                                                   xobjectKinds: ["Fm1": .form],
                                                   resolver: StubResolver(forms: ["Fm1": form]))
        #expect(page.showOps.map(\.stream) == [1])

        let changed = PDFContentStripper.removing([0], from: streams, showOps: page.showOps)
        #expect(changed.keys.sorted() == [1])
        #expect(String(decoding: changed[1] ?? [], as: UTF8.self) == "BT /F1 10 Tf 0 0 Td  ET")
    }

    @Test("removing a Tj leaves every other byte identical")
    func stripTj() {
        let content = "BT /F1 10 Tf 100 700 Td (AB) Tj 0 -14 Td (C) Tj ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([0], from: bytes, showOps: page.showOps)
        #expect(String(decoding: stripped, as: UTF8.self) == "BT /F1 10 Tf 100 700 Td  0 -14 Td (C) Tj ET")
    }

    @Test("removing every show operator keeps the surrounding bytes")
    func stripAll() {
        let content = "BT /F1 10 Tf 100 700 Td (AB) Tj 0 -14 Td (C) Tj ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([0, 1], from: bytes, showOps: page.showOps)
        #expect(String(decoding: stripped, as: UTF8.self) == "BT /F1 10 Tf 100 700 Td  0 -14 Td  ET")
    }

    @Test("removing the line before a ' keeps the next line where it was")
    func stripBeforeQuote() {
        let content = "BT /F1 10 Tf 14 TL 100 700 Td (A) Tj (B) ' ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([0], from: bytes, showOps: page.showOps)
        let after = PDFContentInterpreter.interpret(stripped, fonts: stubFonts)
        #expect(after.glyphs.count == 1)
        #expect(after.glyphs[0].origin == page.glyphs[1].origin)
    }

    @Test("removing a ' replaces it with T* so the next line still starts right")
    func stripQuote() {
        let content = "BT /F1 10 Tf 14 TL 100 700 Td (A) Tj (B) ' (C) Tj ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([1], from: bytes, showOps: page.showOps)
        #expect(String(decoding: stripped, as: UTF8.self).contains("(A) Tj T* (C) Tj"))
        let after = PDFContentInterpreter.interpret(stripped, fonts: stubFonts)
        #expect(after.glyphs.count == 2)
        #expect(after.glyphs[1].origin == CGPoint(x: 100, y: 686))
    }

    @Test("removing the line before a \" keeps the next line where it was")
    func stripBeforeDoubleQuote() {
        let content = "BT /F1 10 Tf 14 TL 100 700 Td (A) Tj 2 1 (B C) \" ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([0], from: bytes, showOps: page.showOps)
        let after = PDFContentInterpreter.interpret(stripped, fonts: stubFonts)
        #expect(after.glyphs.count == 3)
        #expect(after.glyphs[0].origin == page.glyphs[1].origin)
        #expect(after.glyphs[1].origin == page.glyphs[2].origin)
        #expect(after.glyphs[2].origin == page.glyphs[3].origin)
    }

    @Test("removing a \" keeps its spacing change and its line move")
    func stripDoubleQuote() {
        let content = "BT /F1 10 Tf 14 TL 100 700 Td 2 1 (A B) \" (C D) Tj ET"
        let bytes = Array(content.utf8)
        let page = interpret(content)
        let stripped = PDFContentStripper.removing([0], from: bytes, showOps: page.showOps)
        #expect(String(decoding: stripped, as: UTF8.self).contains("2 Tw 1 Tc T* (C D) Tj"))
        let after = PDFContentInterpreter.interpret(stripped, fonts: stubFonts)
        #expect(after.glyphs.count == 3)
        // The next line starts at the same place and keeps the spacing change.
        #expect(after.glyphs[0].origin == CGPoint(x: 100, y: 686))
        #expect(after.glyphs[1].origin == CGPoint(x: 106, y: 686))
        #expect(after.glyphs[2].origin == CGPoint(x: 114, y: 686))
        #expect(page.glyphs[0].origin == after.glyphs[0].origin)
    }

    // MARK: - Integration

    @Test("page 4 of attention.pdf interprets into many show ops inside the media box")
    func attentionPage() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            testDirectory.appendingPathComponent("../../../fixtures/attention.pdf"),
            testDirectory.appendingPathComponent("../../fixtures/attention.pdf"),
            testDirectory.appendingPathComponent("../fixtures/attention.pdf"),
            URL(fileURLWithPath: "fixtures/attention.pdf"),
            URL(fileURLWithPath: "../fixtures/attention.pdf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            try Test.cancel("fixtures/attention.pdf is not available")
        }
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 4) else {
            try Test.cancel("page 4 of attention.pdf is not readable")
        }

        let content = contentStreams(of: page)
        #expect(!content.isEmpty)
        let decoders = fontDecoders(of: page)
        #expect(!decoders.isEmpty)

        let pageContent = PDFContentInterpreter.interpret(content, fonts: decoders)
        #expect(pageContent.showOps.count > 50)

        let mediaBox = page.getBoxRect(.mediaBox)
        let outside = pageContent.glyphs.filter {
            $0.origin.y < mediaBox.minY || $0.origin.y > mediaBox.maxY
        }
        #expect(outside.isEmpty)
    }
}

// MARK: - PDF helpers for the integration test

private func contentStreams(of page: CGPDFPage) -> [UInt8] {
    guard let dictionary = page.dictionary else { return [] }
    var object: CGPDFObjectRef?
    guard CGPDFDictionaryGetObject(dictionary, "Contents", &object), let object else { return [] }

    var data: [UInt8] = []
    var stream: CGPDFStreamRef?
    var array: CGPDFArrayRef?
    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
        data.append(contentsOf: streamBytes(stream))
    } else if CGPDFObjectGetValue(object, .array, &array), let array {
        for index in 0..<CGPDFArrayGetCount(array) {
            if CGPDFArrayGetStream(array, index, &stream), let stream {
                data.append(contentsOf: streamBytes(stream))
                data.append(0x0A)
            }
        }
    }
    return data
}

private func streamBytes(_ stream: CGPDFStreamRef) -> [UInt8] {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) else { return [] }
    return [UInt8](data as Data)
}

private func fontDecoders(of page: CGPDFPage) -> [String: any PDFCharDecoding] {
    guard let resources = inheritedDictionary(page.dictionary, key: "Resources"),
          let fonts = subdictionary(of: resources, key: "Font") else { return [:] }

    final class Collector: @unchecked Sendable {
        var decoders: [String: any PDFCharDecoding] = [:]
    }
    let collector = Collector()
    CGPDFDictionaryApplyBlock(fonts, { key, value, _ in
        let resourceName = String(cString: key)
        var baseFont = resourceName
        if let font = subdictionary(of: value), let baseFontName = name(of: font, key: "BaseFont") {
            baseFont = baseFontName
        }
        collector.decoders[resourceName] = StubFont(fontName: baseFont)
        return true
    }, nil)
    return collector.decoders
}

private func inheritedDictionary(_ page: CGPDFDictionaryRef?, key: String) -> CGPDFDictionaryRef? {
    var current = page
    while let currentDictionary = current {
        if let found = subdictionary(of: currentDictionary, key: key) { return found }
        current = subdictionary(of: currentDictionary, key: "Parent")
    }
    return nil
}

private func subdictionary(of dictionary: CGPDFDictionaryRef, key: String) -> CGPDFDictionaryRef? {
    var value: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
}

private func subdictionary(of object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
    var value: CGPDFDictionaryRef?
    return CGPDFObjectGetValue(object, .dictionary, &value) ? value : nil
}

private func name(of dictionary: CGPDFDictionaryRef, key: String) -> String? {
    var value: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
    return String(cString: value)
}

@Suite struct PDFContentPathRemovalTests {
    @Test func pathsCarryTheirBytesAndCanBeRemoved() {
        let source = "0 0 1 rg 10 10 m 50 10 l S 1 w 2 2 5 5 re f 0 0 m 1 1 l n 3 3 4 4 re f"
        let content = Array(source.utf8)
        let page = PDFContentInterpreter.interpret(content, fonts: [:])
        let paths = page.graphics.filter { $0.kind == .path }
        #expect(paths.count == 3)
        #expect(paths.compactMap { $0.byteRange.map { String(decoding: content[$0], as: UTF8.self) } }
            == ["10 10 m 50 10 l S", "2 2 5 5 re f", "3 3 4 4 re f"])
        let stripped = PDFContentStripper.removing([], from: content, showOps: page.showOps,
                                                   paths: [paths[1].byteRange!])
        #expect(String(decoding: stripped, as: UTF8.self)
            == "0 0 1 rg 10 10 m 50 10 l S 1 w  0 0 m 1 1 l n 3 3 4 4 re f")
    }

    @Test func glyphsCarryTheFillColor() {
        let content = Array("BT /F 10 Tf (a) Tj 1 0 0 rg (b) Tj 0 0 0 1 k (c) Tj 0.5 g (d) Tj ET".utf8)
        let colors = PDFContentInterpreter.interpret(content, fonts: [:]).glyphs.map(\.color)
        #expect(colors == [.black, PDFColor(red: 1, green: 0, blue: 0), .black,
                           PDFColor(red: 0.5, green: 0.5, blue: 0.5)])
    }
}
