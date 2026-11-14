import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import YakuCore

// MARK: - Helpers

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// Wraps `body` in the boilerplate of a ToUnicode CMap stream.
private func cmap(_ body: String) -> PDFToUnicodeCMap {
    PDFToUnicodeCMap(bytes("""
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        \(body)
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """))
}

private func isClose(_ value: CGFloat, _ expected: CGFloat) -> Bool {
    abs(value - expected) < 1e-9
}

private func isClose(_ values: [CGFloat], _ expected: [CGFloat]) -> Bool {
    values.count == expected.count && zip(values, expected).allSatisfy { isClose($0, $1) }
}

/// A PDF file of numbered objects, object 1 being the catalog.
private func pdfDocument(objects: [String]) -> Data {
    var text = "%PDF-1.7\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(text.utf8.count)
        text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = text.utf8.count
    text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
    text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(text.utf8)
}

private func streamObject(_ dictionary: String, _ body: String) -> String {
    "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
}

private func writeTemporaryPDF(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("yaku-fonts-\(UUID().uuidString).pdf")
    try data.write(to: url)
    return url
}

/// A page inherits /Resources from its ancestors when it has none of its own.
private func resources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
    var current = page.dictionary
    while let dictionary = current {
        var found: CGPDFDictionaryRef? = nil
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &found) { return found }
        var parent: CGPDFDictionaryRef? = nil
        current = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) ? parent : nil
    }
    return nil
}

private func content(of page: CGPDFPage) -> [UInt8] {
    guard let dictionary = page.dictionary else { return [] }
    var object: CGPDFObjectRef? = nil
    guard CGPDFDictionaryGetObject(dictionary, "Contents", &object), let object else { return [] }
    var format = CGPDFDataFormat.raw
    var stream: CGPDFStreamRef? = nil
    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
        return CGPDFStreamCopyData(stream, &format).map { [UInt8]($0 as Data) } ?? []
    }
    var array: CGPDFArrayRef? = nil
    guard CGPDFObjectGetValue(object, .array, &array), let array else { return [] }
    var data: [UInt8] = []
    for index in 0..<CGPDFArrayGetCount(array) {
        var stream: CGPDFStreamRef? = nil
        guard CGPDFArrayGetStream(array, index, &stream), let stream,
              let part = CGPDFStreamCopyData(stream, &format) else { continue }
        data += [UInt8](part as Data)
        data.append(0x0A)
    }
    return data
}

/// String operands of every text-showing operator, in content stream order.
private func showOperands(in content: [UInt8]) -> [[[UInt8]]] {
    func isWhiteSpace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }
    func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    var shows: [[[UInt8]]] = []
    var pending: [[UInt8]] = []
    var index = 0
    while index < content.count {
        let byte = content[index]
        if isWhiteSpace(byte) {
            index += 1
        } else if byte == 0x25 {
            while index < content.count, content[index] != 0x0A, content[index] != 0x0D { index += 1 }
        } else if byte == 0x28 {
            var depth = 1
            var string: [UInt8] = []
            index += 1
            while index < content.count, depth > 0 {
                let current = content[index]
                if current == 0x5C {
                    index += 1
                    if index < content.count { string.append(content[index]) }
                    index += 1
                    continue
                }
                if current == 0x28 { depth += 1 }
                if current == 0x29 {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        break
                    }
                }
                string.append(current)
                index += 1
            }
            pending.append(string)
        } else if byte == 0x3C {
            if index + 1 < content.count, content[index + 1] == 0x3C {
                index += 2
                continue
            }
            index += 1
            var digits: [UInt8] = []
            while index < content.count, content[index] != 0x3E {
                if !isWhiteSpace(content[index]) { digits.append(content[index]) }
                index += 1
            }
            index += 1
            pending.append(PDFToUnicodeCMapTokenizer.hexadecimalBytes(digits))
        } else if byte == 0x3E {
            index += min(2, content.count - index)
        } else if byte == 0x5B || byte == 0x5D {
            index += 1
        } else if byte == 0x2F {
            index += 1
            while index < content.count, !isWhiteSpace(content[index]), !isDelimiter(content[index]) { index += 1 }
        } else {
            let start = index
            while index < content.count, !isWhiteSpace(content[index]), !isDelimiter(content[index]) { index += 1 }
            if index == start {
                index += 1
                continue
            }
            let word = String(decoding: content[start..<index], as: UTF8.self)
            // Numbers are operands, so they keep the strings collected so far.
            if Double(word) != nil { continue }
            if word == "Tj" || word == "TJ" || word == "'" || word == "\"" {
                shows.append(pending)
            }
            pending.removeAll()
        }
    }
    return shows
}

/// Draws one line with CoreText into a PDF context, which is how the app's own
/// typesetter writes Japanese text.
private func draw(_ text: String, font name: String, at point: CGPoint, in context: CGContext) {
    let font = CTFontCreateWithName(name as CFString, 12, nil)
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}

private func coreTextPDF(japanese: String, latin: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("yaku-fonts-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    draw(japanese, font: "HiraMinProN-W3", at: CGPoint(x: 20, y: 150), in: context)
    draw(latin, font: "Helvetica", at: CGPoint(x: 20, y: 100), in: context)
    context.endPDFPage()
    context.closePDF()
    return url
}

/// The fixture directory sits next to the package, not inside it.
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures")
        .appendingPathComponent(name)
}

// MARK: - Tests

@Suite("PDF font decoding")
struct PDFFontDecoderTests {
    @Test("bfchar and both bfrange forms map codes to UTF-16")
    func cmapMappings() {
        let map = cmap("""
            1 begincodespacerange
            <00> <FF>
            endcodespacerange
            2 beginbfchar
            <41> <0041>
            <02> <00660069>
            endbfchar
            2 beginbfrange
            <20> <22> <0061>
            <30> <32> [<0031> <0032> <0033>]
            endbfrange
            """)
        #expect(map.codeSpaceRanges == [.init(low: 0x00, high: 0xFF, byteLength: 1)])
        #expect(map.unicode(for: 0x41) == "A")
        #expect(map.unicode(for: 0x02) == "fi")
        #expect(map.unicode(for: 0x20) == "a")
        #expect(map.unicode(for: 0x21) == "b")
        #expect(map.unicode(for: 0x22) == "c")
        #expect(map.unicode(for: 0x30) == "1")
        #expect(map.unicode(for: 0x32) == "3")
        #expect(map.unicode(for: 0x40) == nil)
    }

    @Test("surrogate pairs and multi-character destinations survive")
    func cmapSurrogates() {
        let map = cmap("""
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange
            3 beginbfchar
            <0001> <D835DC00>
            <0002> <006600660069>
            <0003> <0066006C>
            endbfchar
            """)
        #expect(map.unicode(for: 1) == "\u{1D400}")
        #expect(map.unicode(for: 2) == "ffi")
        #expect(map.unicode(for: 3) == "fl")
    }

    @Test("codespace ranges decide one and two byte codes")
    func cmapCodeLength() {
        let map = cmap("""
            2 begincodespacerange
            <00> <7F>
            <8000> <FFFF>
            endcodespacerange
            """)
        #expect(map.codeSpaceRanges.map(\.byteLength) == [1, 2])
        #expect(map.codeLength(in: [0x41, 0x00], at: 0) == 1)
        #expect(map.codeLength(in: [0x80, 0x41], at: 0) == 2)
        #expect(map.codeLength(in: [0xFF, 0xFF], at: 0) == 2)
        #expect(map.codeLength(in: [0x80], at: 0) == nil)
        #expect(map.codeLength(in: [], at: 0) == nil)
    }

    @Test("glyph names map through the usual rules")
    func glyphNames() {
        #expect(PDFGlyphNames.unicode(for: "quotesingle") == "'")
        #expect(PDFGlyphNames.unicode(for: "hyphen") == "-")
        #expect(PDFGlyphNames.unicode(for: "period") == ".")
        #expect(PDFGlyphNames.unicode(for: "parenleft") == "(")
        #expect(PDFGlyphNames.unicode(for: "uni0041") == "A")
        #expect(PDFGlyphNames.unicode(for: "uni00410042") == "AB")
        #expect(PDFGlyphNames.unicode(for: "u0041") == "A")
        #expect(PDFGlyphNames.unicode(for: "u1D400") == "\u{1D400}")
        #expect(PDFGlyphNames.unicode(for: "a.sc") == "a")
        #expect(PDFGlyphNames.unicode(for: "f_i") == "fi")
        #expect(PDFGlyphNames.unicode(for: "fi") == "\u{FB01}")
        #expect(PDFGlyphNames.unicode(for: "ffi") == "\u{FB03}")
        #expect(PDFGlyphNames.unicode(for: "quotedblleft") == "\u{201C}")
        #expect(PDFGlyphNames.unicode(for: "quoteleft") == "\u{2018}")
        #expect(PDFGlyphNames.unicode(for: "endash") == "\u{2013}")
        #expect(PDFGlyphNames.unicode(for: "emdash") == "\u{2014}")
        #expect(PDFGlyphNames.unicode(for: "bullet") == "\u{2022}")
        #expect(PDFGlyphNames.unicode(for: "ellipsis") == "\u{2026}")
        #expect(PDFGlyphNames.unicode(for: "dagger") == "\u{2020}")
        #expect(PDFGlyphNames.unicode(for: "daggerdbl") == "\u{2021}")
        #expect(PDFGlyphNames.unicode(for: "section") == "\u{00A7}")
        #expect(PDFGlyphNames.unicode(for: "paragraph") == "\u{00B6}")
        #expect(PDFGlyphNames.unicode(for: "minus") == "\u{2212}")
        #expect(PDFGlyphNames.unicode(for: "multiply") == "\u{00D7}")
        #expect(PDFGlyphNames.unicode(for: "divide") == "\u{00F7}")
        #expect(PDFGlyphNames.unicode(for: "Aacute") == "\u{00C1}")
        #expect(PDFGlyphNames.unicode(for: "eacute") == "\u{00E9}")
        #expect(PDFGlyphNames.unicode(for: "Scaron") == "\u{0160}")
        #expect(PDFGlyphNames.unicode(for: "germandbls") == "\u{00DF}")
        #expect(PDFGlyphNames.unicode(for: "alpha") == "\u{03B1}")
        #expect(PDFGlyphNames.unicode(for: "Omega") == "\u{03A9}")
        #expect(PDFGlyphNames.unicode(for: "infinity") == "\u{221E}")
        #expect(PDFGlyphNames.unicode(for: "summation") == "\u{2211}")
        #expect(PDFGlyphNames.unicode(for: "integral") == "\u{222B}")
        #expect(PDFGlyphNames.unicode(for: "radical") == "\u{221A}")
        #expect(PDFGlyphNames.unicode(for: "lessequal") == "\u{2264}")
        #expect(PDFGlyphNames.unicode(for: "greaterequal") == "\u{2265}")
        #expect(PDFGlyphNames.unicode(for: "notequal") == "\u{2260}")
        #expect(PDFGlyphNames.unicode(for: "approxequal") == "\u{2248}")
        #expect(PDFGlyphNames.unicode(for: "element") == "\u{2208}")
        #expect(PDFGlyphNames.unicode(for: "arrowright") == "\u{2192}")
        #expect(PDFGlyphNames.unicode(for: "arrowleft") == "\u{2190}")
        #expect(PDFGlyphNames.unicode(for: "partialdiff") == "\u{2202}")
        #expect(PDFGlyphNames.unicode(for: "nabla") == "\u{2207}")
        #expect(PDFGlyphNames.unicode(for: "noSuchGlyph") == nil)
        #expect(PDFGlyphNames.unicode(for: "") == nil)
    }

    @Test("the predefined encodings hold the expected glyph names")
    func encodings() throws {
        let winAnsi = try #require(PDFGlyphNames.encoding(named: "WinAnsiEncoding"))
        #expect(winAnsi[0x41] == "A")
        #expect(winAnsi[0x93] == "quotedblleft")
        #expect(winAnsi[0xE9] == "eacute")
        #expect(winAnsi[0x80] == "Euro")
        #expect(winAnsi[0x81] == "")
        let macRoman = try #require(PDFGlyphNames.encoding(named: "MacRomanEncoding"))
        #expect(macRoman[0x41] == "A")
        #expect(macRoman[0x8E] == "eacute")
        #expect(macRoman[0xCA] == "space")
        let standard = try #require(PDFGlyphNames.encoding(named: "StandardEncoding"))
        #expect(standard[0x27] == "quoteright")
        #expect(standard[0x60] == "quoteleft")
        #expect(standard[0xAE] == "fi")
        #expect(PDFGlyphNames.encoding(named: "NoSuchEncoding") == nil)
    }

    @Test("subset prefixes are removed from the font name")
    func subsetPrefix() {
        #expect(PDFFontDecoder.strippingSubsetPrefix("ABCDEF+NimbusRomNo9L-Regu") == "NimbusRomNo9L-Regu")
        #expect(PDFFontDecoder.strippingSubsetPrefix("AAAAAB+HiraMinProN-W3") == "HiraMinProN-W3")
        #expect(PDFFontDecoder.strippingSubsetPrefix("ABCDE+X") == "ABCDE+X")
        #expect(PDFFontDecoder.strippingSubsetPrefix("ABCDEFG+X") == "ABCDEFG+X")
        #expect(PDFFontDecoder.strippingSubsetPrefix("Helvetica") == "Helvetica")
        #expect(PDFFontDecoder.strippingSubsetPrefix("") == "")
    }

    @Test("a simple font decodes Differences over its base encoding")
    func simpleFont() {
        let description = PDFFontDescription(
            kind: .type1,
            baseFont: "ABCDEF+Test-Bold",
            firstChar: 65,
            widths: [600, 700, 800],
            missingWidth: 400,
            baseEncoding: "WinAnsiEncoding",
            differences: [65: "alpha", 66: "beta"]
        )
        let decoder = PDFFontDecoder(description)
        #expect(decoder.fontName == "Test-Bold")
        let characters = decoder.decode([65, 66, 67, 90])
        #expect(characters.map(\.code) == [65, 66, 67, 90])
        #expect(characters.map(\.unicode) == ["\u{03B1}", "\u{03B2}", "C", "Z"])
        #expect(isClose(characters.map(\.width), [0.6, 0.7, 0.8, 0.4]))
        #expect(characters.allSatisfy { !$0.isWordSpace })
    }

    @Test("WinAnsi codes become Unicode and word spaces are code 32")
    func winAnsiFont() {
        let decoder = PDFFontDecoder(PDFFontDescription(
            kind: .type1, baseFont: "Helvetica", baseEncoding: "WinAnsiEncoding"))
        #expect(decoder.decode([0x93]).first?.unicode == "\u{201C}")
        #expect(decoder.decode([0xE9]).first?.unicode == "\u{00E9}")
        #expect(decoder.decode([0x80]).first?.unicode == "\u{20AC}")
        #expect(decoder.decode([0x20]).first?.isWordSpace == true)
        #expect(decoder.decode([0x41]).first?.isWordSpace == false)
    }

    @Test("a Type 0 Identity-H font reads two byte codes and the W array")
    func identityHFont() {
        let description = PDFFontDescription(
            kind: .type0,
            baseFont: "ABCDEF+TestCID",
            cidEncoding: "Identity-H",
            defaultCIDWidth: 1000,
            cidWidths: [1: 500, 2: 250]
        )
        let decoder = PDFFontDecoder(description)
        #expect(decoder.fontName == "TestCID")
        let characters = decoder.decode([0x00, 0x01, 0x00, 0x02, 0x00, 0x03])
        #expect(characters.map(\.code) == [1, 2, 3])
        #expect(isClose(characters.map(\.width), [0.5, 0.25, 1.0]))
        #expect(characters.allSatisfy { $0.unicode.isEmpty })
        #expect(characters.allSatisfy { !$0.isWordSpace })
    }

    @Test("a Type 3 font scales widths through its font matrix")
    func type3Font() {
        let description = PDFFontDescription(
            kind: .type3,
            baseFont: "F3",
            firstChar: 0,
            widths: [500, 250],
            fontMatrix: CGAffineTransform(scaleX: 0.002, y: 0.002)
        )
        let decoder = PDFFontDecoder(description)
        #expect(isClose(decoder.decode([0, 1]).map(\.width), [1.0, 0.5]))
    }

    @Test("codes outside the Widths array use the missing width")
    func missingWidth() {
        let description = PDFFontDescription(
            kind: .trueType, baseFont: "SomeFont", firstChar: 10, widths: [500], missingWidth: 300)
        let decoder = PDFFontDecoder(description)
        #expect(isClose(decoder.decode([10]).first?.width ?? 0, 0.5))
        #expect(isClose(decoder.decode([9]).first?.width ?? 0, 0.3))
        #expect(isClose(decoder.decode([11]).first?.width ?? 0, 0.3))
    }

    @Test("standard 14 fonts without Widths use average metrics")
    func standard14Widths() {
        let courier = PDFFontDecoder(PDFFontDescription(kind: .type1, baseFont: "Courier"))
        #expect(isClose(courier.decode([0x41]).first?.width ?? 0, 0.6))
        #expect(isClose(courier.decode([0x20]).first?.width ?? 0, 0.6))
        let times = PDFFontDecoder(PDFFontDescription(kind: .type1, baseFont: "Times-Roman"))
        #expect(isClose(times.decode([0x41]).first?.width ?? 0, 0.667))
        #expect(isClose(times.decode([0x61]).first?.width ?? 0, 0.5))
        #expect(isClose(times.decode([0x20]).first?.width ?? 0, 0.25))
        #expect(isClose(times.decode([0x2E]).first?.width ?? 0, 0.333))
        let helvetica = PDFFontDecoder(PDFFontDescription(kind: .type1, baseFont: "Helvetica"))
        #expect(isClose(helvetica.decode([0x20]).first?.width ?? 0, 0.278))
        #expect(isClose(helvetica.decode([0x61]).first?.width ?? 0, 0.556))
        let unknown = PDFFontDecoder(PDFFontDescription(kind: .type1, baseFont: "Mystery"))
        #expect(isClose(unknown.decode([0x41]).first?.width ?? 1, 0))
    }

    @Test("ToUnicode wins over Differences and the base encoding")
    func toUnicodePrecedence() {
        let map = cmap("""
            1 begincodespacerange
            <00> <FF>
            endcodespacerange
            1 beginbfchar
            <41> <03B1>
            endbfchar
            """)
        let decoder = PDFFontDecoder(PDFFontDescription(
            kind: .type1,
            baseFont: "Test",
            baseEncoding: "WinAnsiEncoding",
            differences: [0x41: "beta"],
            toUnicode: bytes("""
                /CIDInit /ProcSet findresource begin
                12 dict begin
                begincmap
                1 begincodespacerange
                <00> <FF>
                endcodespacerange
                1 beginbfchar
                <41> <03B1>
                endbfchar
                endcmap
                end
                end
                """)
        ))
        #expect(map.unicode(for: 0x41) == "\u{03B1}")
        #expect(decoder.decode([0x41]).first?.unicode == "\u{03B1}")
        #expect(decoder.decode([0x42]).first?.unicode == "B")
    }

    @Test("an encoding we do not ship decodes to nothing")
    func unknownEncoding() {
        let decoder = PDFFontDecoder(PDFFontDescription(
            kind: .type1, baseFont: "Test", baseEncoding: "MacExpertEncoding"))
        #expect(decoder.decode([0x41]).first?.unicode == "")
    }

    @Test("a symbolic standard 14 font decodes nothing without Differences")
    func symbolicStandard14() {
        let plain = PDFFontDecoder(PDFFontDescription(
            kind: .type1, baseFont: "Symbol", isSymbolicStandard14: true))
        #expect(plain.decode([0x41]).first?.unicode == "")
        let mapped = PDFFontDecoder(PDFFontDescription(
            kind: .type1, baseFont: "Symbol", differences: [0x41: "alpha"], isSymbolicStandard14: true))
        #expect(mapped.decode([0x41]).first?.unicode == "\u{03B1}")
    }

    @Test("style detection for real font names")
    func styles() {
        let cases: [(String, PDFFontStyle)] = [
            ("NimbusRomNo9L-Regu", PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                                isMath: false, isMonospace: false)),
            ("NimbusRomNo9L-Medi", PDFFontStyle(isSerif: true, isBold: true, isItalic: false,
                                                isMath: false, isMonospace: false)),
            ("CMMI10", PDFFontStyle(isSerif: false, isBold: false, isItalic: true,
                                    isMath: true, isMonospace: false)),
            ("CMR10", PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                   isMath: false, isMonospace: false)),
            ("Helvetica-Bold", PDFFontStyle(isSerif: false, isBold: true, isItalic: false,
                                            isMath: false, isMonospace: false)),
            ("CMTT10", PDFFontStyle(isSerif: false, isBold: false, isItalic: false,
                                    isMath: false, isMonospace: true)),
            ("HiraMinProN-W3", PDFFontStyle(isSerif: true, isBold: false, isItalic: false,
                                            isMath: false, isMonospace: false)),
            ("HiraKakuProN-W6", PDFFontStyle(isSerif: false, isBold: true, isItalic: false,
                                             isMath: false, isMonospace: false)),
            ("Times-Italic", PDFFontStyle(isSerif: true, isBold: false, isItalic: true,
                                          isMath: false, isMonospace: false)),
            ("CMSY10", PDFFontStyle(isSerif: false, isBold: false, isItalic: false,
                                    isMath: true, isMonospace: false)),
        ]
        for (name, expected) in cases {
            #expect(PDFFontDecoder.style(forBaseFont: name, flags: 0) == expected, "\(name)")
        }
        // FontDescriptor flags: serif (2), italic (64) and ForceBold (1 << 18).
        #expect(PDFFontDecoder.style(forBaseFont: "Mystery", flags: 2 | 64 | (1 << 18))
            == PDFFontStyle(isSerif: true, isBold: true, isItalic: true, isMath: false, isMonospace: false))
        #expect(PDFFontDecoder.style(forBaseFont: "Mystery", flags: 1)
            == PDFFontStyle(isSerif: false, isBold: false, isItalic: false, isMath: false, isMonospace: true))
    }

    @Test("attention.pdf page 4 reads its NimbusRomNo9L font and decodes ASCII")
    func attentionPaper() throws {
        let url = fixtureURL("attention.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 4))
        let fonts = PDFFontReader.fonts(in: try #require(resources(of: page)))
        let key = try #require(fonts.keys.first {
            fonts[$0]?.baseFont.contains("NimbusRomNo9L-Regu") == true
        })
        let description = try #require(fonts[key])
        #expect(description.kind == .type1)
        #expect(description.baseFont == "AECCXO+NimbusRomNo9L-Regu")
        #expect(description.firstChar == 2)
        #expect(description.widths.count == 251)
        #expect(description.differences[65] == "A")
        #expect(description.descriptorFlags == 4)
        #expect(description.toUnicode != nil)

        let decoder = PDFFontDecoder(description)
        #expect(decoder.fontName == "NimbusRomNo9L-Regu")
        #expect(decoder.style.isSerif)
        #expect(!decoder.style.isBold)
        let letters = decoder.decode([65, 66, 67])
        #expect(letters.map(\.unicode) == ["A", "B", "C"])
        #expect(isClose(letters[0].width, 0.722))
        // The TeX CMap of the fixture maps the fi ligature code to two characters.
        #expect(decoder.decode([0x02]).first?.unicode == "fi")
    }

    @Test("a CoreText PDF is read back and its Latin text round trips")
    func coreTextPDFFonts() throws {
        let japanese = "日本語の組版テスト"
        let latin = "Hello world"
        let url = try coreTextPDF(japanese: japanese, latin: latin)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let fonts = PDFFontReader.fonts(in: try #require(resources(of: page)))
        let shows = showOperands(in: content(of: page))
        #expect(shows.count == 2)

        let cid = try #require(fonts.values.first { $0.kind == .type0 })
        #expect(cid.baseFont.hasSuffix("HiraMinProN-W3"))
        #expect(cid.cidEncoding == "Identity-H")
        #expect(cid.defaultCIDWidth == 1000)
        let cidDecoder = PDFFontDecoder(cid)
        #expect(cidDecoder.fontName == "HiraMinProN-W3")
        #expect(cidDecoder.style.isSerif)
        let japaneseCharacters = shows[0].flatMap { cidDecoder.decode($0) }
        // One code per character proves the two byte splitting of Identity-H.
        #expect(japaneseCharacters.count == japanese.count)
        #expect(isClose(japaneseCharacters.map(\.width), [CGFloat](repeating: 1, count: japanese.count)))
        // Quartz writes no ToUnicode CMap for a CID font, and the embedded CFF
        // subset is keyed by Adobe-Japan1 CIDs, which carry no Unicode.
        #expect(japaneseCharacters.allSatisfy { $0.unicode.isEmpty })

        let latinFont = try #require(fonts.values.first { $0.kind == .trueType })
        #expect(latinFont.baseEncoding == "MacRomanEncoding")
        let latinDecoder = PDFFontDecoder(latinFont)
        let latinText = shows[1].flatMap { latinDecoder.decode($0) }.map(\.unicode).joined()
        #expect(latinText == latin)
    }

    @Test("a hand-built Identity-H PDF decodes Japanese through its ToUnicode CMap")
    func identityHJapanese() throws {
        let text = "日本語の組版テスト"
        let codes = (1...text.count).map { String(format: "%04X", $0) }
        let destinations = text.utf16.map { String(format: "%04X", $0) }
        let pairs = zip(codes, destinations).map { "<\($0)> <\($1)>" }.joined(separator: "\n")
        let toUnicode = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange
            \(text.count) beginbfchar
            \(pairs)
            endbfchar
            endcmap
            end
            end
            """
        let data = pdfDocument(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+HiraMinProN-W3 /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 7 0 R >>",
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+HiraMinProN-W3 /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 1000 /W [1 [500 600] 3 5 700] /FontDescriptor << /Type /FontDescriptor /FontName /ABCDEF+HiraMinProN-W3 /Flags 4 >> >>",
            streamObject("", "BT /F1 12 Tf 1 0 0 1 20 150 Tm <\(codes.joined(separator: " "))> Tj ET"),
            streamObject("", toUnicode),
        ])
        let url = try writeTemporaryPDF(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let fonts = PDFFontReader.fonts(in: try #require(resources(of: page)))
        let description = try #require(fonts["F1"])
        #expect(description.kind == .type0)
        #expect(description.cidEncoding == "Identity-H")
        #expect(description.defaultCIDWidth == 1000)
        #expect(description.cidWidths[1] == 500)
        #expect(description.cidWidths[2] == 600)
        #expect(description.cidWidths[3] == 700)
        #expect(description.cidWidths[5] == 700)
        #expect(description.cidWidths[6] == nil)

        let decoder = PDFFontDecoder(description)
        #expect(decoder.fontName == "HiraMinProN-W3")
        let shows = showOperands(in: content(of: page))
        #expect(shows.count == 1)
        let characters = shows[0].flatMap { decoder.decode($0) }
        #expect(characters.map(\.code) == Array(1...text.count))
        #expect(characters.map(\.unicode).joined() == text)
        #expect(isClose(characters.map(\.width), [0.5, 0.6, 0.7, 0.7, 0.7, 1, 1, 1, 1]))
    }
}

@Suite struct PDFGlyphNameDigitTests {
    @Test func digitNamesAreSpelledOut() {
        #expect(PDFGlyphNames.unicode(for: "zero") == "0")
        #expect(PDFGlyphNames.unicode(for: "seven") == "7")
        #expect(PDFGlyphNames.encoding(named: "WinAnsiEncoding")?[0x37] == "seven")
        #expect(PDFGlyphNames.encoding(named: "StandardEncoding")?[0x30] == "zero")
    }

    @Test func type1DifferencesDecodeDigits() {
        var description = PDFFontDescription(kind: .type1, baseFont: "ABCDEF+NimbusRomNo9L-Regu")
        description.differences = [48: "zero", 49: "one", 57: "nine"]
        let text = PDFFontDecoder(description).decode([48, 49, 57]).map(\.unicode).joined()
        #expect(text == "019")
    }
}
