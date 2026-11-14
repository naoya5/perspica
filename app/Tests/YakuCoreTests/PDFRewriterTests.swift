import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import YakuCore

private let attentionFixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // PDFRewriterTests.swift
    .deletingLastPathComponent() // YakuCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // app
    .appendingPathComponent("fixtures/attention.pdf")

@Suite("PDF rewriter")
struct PDFRewriterTests {
    // MARK: - Round trip

    @Test("a rewritten document keeps pages, boxes, rotation, text and annotations")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try writeSamplePDF(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))

        let output = try PDFRewriter.rewrite(source, replacements: [:])
        let outputURL = directory.appendingPathComponent("copy.pdf")
        try output.write(to: outputURL)
        let copy = try #require(CGPDFDocument(outputURL as CFURL))

        #expect(copy.numberOfPages == source.numberOfPages)
        #expect(copy.numberOfPages == 3)
        for index in 1...source.numberOfPages {
            let original = try #require(source.page(at: index))
            let rewritten = try #require(copy.page(at: index))
            #expect(rewritten.getBoxRect(.mediaBox) == original.getBoxRect(.mediaBox))
            #expect(rewritten.getBoxRect(.cropBox) == original.getBoxRect(.cropBox))
            #expect(rewritten.rotationAngle == original.rotationAngle)
            #expect(annotationCount(of: rewritten) == annotationCount(of: original))
        }
        #expect(annotationCount(of: try #require(copy.page(at: 2))) == 2)

        let sourceText = try #require(PDFDocument(url: sourceURL)?.string)
        let copyText = try #require(PDFDocument(url: outputURL)?.string)
        #expect(copyText == sourceText)

        // The internal destination points at the reserved page object, so the
        // page tree holds one dictionary per page and no duplicate copy.
        #expect(pageObjectCount(in: output) == 3)
        let pdf = try #require(PDFDocument(url: outputURL))
        let linkPage = try #require(pdf.page(at: 1))
        let target = try #require(linkPage.annotations.compactMap(\.destination).first?.page)
        #expect(pdf.index(for: target) == 1)
        #expect(output.starts(with: Data("%PDF-1.7".utf8)))
        #expect(output.suffix(6) == Data("%%EOF\n".utf8))
    }

    // MARK: - Replacement

    @Test("replacing one page's content changes only that page")
    func replacement() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try writeSamplePDF(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))

        let marker = "0 0 1 rg 10 10 50 50 re f"
        let output = try PDFRewriter.rewrite(source, replacements: [1: Array(marker.utf8)])
        let outputURL = directory.appendingPathComponent("replaced.pdf")
        try output.write(to: outputURL)
        let copy = try #require(CGPDFDocument(outputURL as CFURL))

        let replacedPage = try #require(copy.page(at: 2))
        let replacedContent = String(decoding: PDFRewriter.content(of: replacedPage), as: UTF8.self)
        #expect(replacedContent == marker)

        let originalPage = try #require(source.page(at: 2))
        let before = try render(originalPage)
        let after = try render(replacedPage)
        #expect(meanAbsoluteDifference(before, after) > 5)

        for index in [1, 3] {
            let original = try render(try #require(source.page(at: index)))
            let rewritten = try render(try #require(copy.page(at: index)))
            #expect(original.pixels == rewritten.pixels)
        }
    }

    // MARK: - Fixture

    @Test("the attention fixture keeps its pages, text and rendering",
          .enabled(if: FileManager.default.fileExists(atPath: attentionFixtureURL.path)))
    func attentionFixture() throws {
        let source = try #require(CGPDFDocument(attentionFixtureURL as CFURL))
        #expect(source.numberOfPages == 15)

        let output = try PDFRewriter.rewrite(source, replacements: [:])
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("attention-copy.pdf")
        try output.write(to: outputURL)
        let copy = try #require(CGPDFDocument(outputURL as CFURL))
        #expect(copy.numberOfPages == 15)
        #expect(pageObjectCount(in: output) == 15)
        for index in 1...source.numberOfPages {
            let original = try #require(source.page(at: index))
            let rewritten = try #require(copy.page(at: index))
            #expect(annotationCount(of: rewritten) == annotationCount(of: original))
            #expect(rewritten.rotationAngle == original.rotationAngle)
        }

        let sourceText = try #require(PDFDocument(url: attentionFixtureURL)?.string)
        let copyText = try #require(PDFDocument(url: outputURL)?.string)
        #expect(abs(copyText.count - sourceText.count) <= max(1, sourceText.count / 100))

        // The paper links its citations with named destinations. They must
        // still resolve, which fails when a page is copied twice.
        let copyPDF = try #require(PDFDocument(url: outputURL))
        let destinations = (0..<copyPDF.pageCount).flatMap { copyPDF.page(at: $0)?.annotations ?? [] }
            .compactMap(\.destination)
        #expect(!destinations.isEmpty)
        #expect(destinations.allSatisfy { $0.page != nil })

        for index in [1, 3, 4] {
            let original = try render(try #require(source.page(at: index)))
            let rewritten = try render(try #require(copy.page(at: index)))
            #expect(meanAbsoluteDifference(original, rewritten) < 1.0)
        }

        let inputSize = try Data(contentsOf: attentionFixtureURL).count
        #expect(output.count <= inputSize * 3)
    }

    // MARK: - File structure

    @Test("the cross-reference table points at every object")
    func crossReferenceTable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try writeSamplePDF(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))
        let output = try PDFRewriter.rewrite(source, replacements: [1: Array("0 0 1 rg".utf8)])

        let marker = try #require(output.range(of: Data("startxref".utf8), options: .backwards))
        var index = marker.upperBound
        while index < output.endIndex, output[index] < 0x30 || output[index] > 0x39 { index += 1 }
        let digits = output[index...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        let xrefOffset = try #require(Int(String(decoding: digits, as: UTF8.self)))
        #expect(String(decoding: output[xrefOffset..<(xrefOffset + 4)], as: UTF8.self) == "xref")

        let headerStart = xrefOffset + "xref\n".utf8.count
        let headerEnd = try #require(output[headerStart...].firstIndex(of: 0x0A))
        let header = String(decoding: output[headerStart..<headerEnd], as: UTF8.self).split(separator: " ")
        #expect(header.count == 2)
        #expect(header.first == "0")
        let count = try #require(header.count == 2 ? Int(header[1]) : nil)
        #expect(count > 1)

        var cursor = headerEnd + 1
        #expect(String(decoding: output[cursor..<(cursor + 20)], as: UTF8.self) == "0000000000 65535 f \n")
        cursor += 20
        for id in 1..<count {
            let entry = output[cursor..<(cursor + 20)]
            let offset = try #require(Int(String(decoding: entry.prefix(10), as: UTF8.self)))
            #expect(entry[entry.startIndex + 17] == UInt8(ascii: "n"))
            let objectHeader = "\(id) 0 obj"
            #expect(String(decoding: output[offset..<(offset + objectHeader.utf8.count)], as: UTF8.self)
                == objectHeader)
            cursor += 20
        }
    }

    // MARK: - Content streams

    @Test("page content concatenates multiple streams with a newline")
    func multipleContentStreams() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("two-streams.pdf")
        try makeTwoStreamPDF().write(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))
        let page = try #require(source.page(at: 1))

        let content = PDFRewriter.content(of: page)
        #expect(String(decoding: content, as: UTF8.self) == "0 0 1 rg\n1 0 0 rg")

        let output = try PDFRewriter.rewrite(source, replacements: [:])
        let outputURL = directory.appendingPathComponent("copy.pdf")
        try output.write(to: outputURL)
        let copy = try #require(CGPDFDocument(outputURL as CFURL))
        #expect(copy.numberOfPages == 1)
        let copiedPage = try #require(copy.page(at: 1))
        #expect(PDFRewriter.content(of: copiedPage) == content)
        #expect(copiedPage.getBoxRect(.mediaBox) == page.getBoxRect(.mediaBox))
    }

    // MARK: - Form streams

    @Test("replacing a form's content changes its text and leaves other pages alone")
    func formStreamReplacement() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("form-reprint.pdf")
        try writeFormReprint(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))

        let reading = PDFPageReader.read(try #require(source.page(at: 2)))
        let form = try #require(reading.formStreams[1])
        let key = unsafeBitCast(form, to: UnsafeRawPointer.self)
        // The new content has to use a font the form already has.
        let fontName = try #require(firstFontName(in: reading.content.streams[1]))
        let replacement = Array("BT /\(fontName) 18 Tf 20 300 Td (alpha text form) Tj ET".utf8)

        let output = try PDFRewriter.rewrite(source, replacements: [:],
                                             streamReplacements: [key: replacement])
        let outputURL = directory.appendingPathComponent("form-replaced.pdf")
        try output.write(to: outputURL)

        let copy = try #require(PDFDocument(url: outputURL))
        #expect(copy.pageCount == 2)
        #expect(copy.page(at: 0)?.string?.contains("Direct page text") == true)
        let formText = try #require(copy.page(at: 1)?.string)
        #expect(formText.contains("alpha text form"))
        #expect(!formText.contains("Form text alpha"))

        // The form kept the dictionary entries its new content needs.
        let copyDocument = try #require(CGPDFDocument(outputURL as CFURL))
        let copyReading = PDFPageReader.read(try #require(copyDocument.page(at: 2)))
        #expect(String(decoding: copyReading.content.streams[1], as: UTF8.self).contains("alpha text form"))
        let copiedForm = try #require(copyReading.formStreams[1])
        let dictionary = try #require(CGPDFStreamGetDictionary(copiedForm))
        var box: CGPDFArrayRef? = nil
        #expect(CGPDFDictionaryGetArray(dictionary, "BBox", &box))
        var resources: CGPDFDictionaryRef? = nil
        #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
    }

    // MARK: - Encrypted documents

    @Test("an encrypted document is rejected")
    func encryptedDocument() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("encrypted.pdf")
        try makeEncryptedPDF().write(to: sourceURL)
        let source = try #require(CGPDFDocument(sourceURL as CFURL))
        #expect(source.isEncrypted)
        #expect(throws: PDFRewriteError.encrypted) {
            _ = try PDFRewriter.rewrite(source, replacements: [:])
        }
    }

    // MARK: - zlib

    @Test("zlib round trips random, text and empty data")
    func zlibRoundTrip() {
        let random = Data((0..<100_000).map { _ in UInt8.random(in: .min ... .max) })
        #expect(PDFZlib.decompress(PDFZlib.compress(random)) == random)

        let text = Data(String(repeating: "PDF rewriter ", count: 1_000).utf8)
        let compressed = PDFZlib.compress(text)
        #expect(compressed.prefix(2) == Data([0x78, 0x9C]))
        #expect(PDFZlib.decompress(compressed) == text)

        #expect(PDFZlib.decompress(PDFZlib.compress(Data())) == Data())

        // A damaged checksum is rejected, and so is data that is not zlib.
        var damaged = compressed
        damaged[damaged.endIndex - 1] ^= 0xFF
        #expect(PDFZlib.decompress(damaged) == nil)
        #expect(PDFZlib.decompress(Data()) == nil)
        #expect(PDFZlib.decompress(Data([0x78, 0x9C, 0x01])) == nil)
        #expect(PDFZlib.decompress(text) == nil)
    }
}

// MARK: - Sample documents

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PDFRewriterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Three pages: text and a path, text with an image and two links, and a
/// rotated page with text and a stroked path.
private func writeSamplePDF(to url: URL) throws {
    var defaultBox = CGRect(x: 0, y: 0, width: 400, height: 500)
    let context = try #require(CGContext(url as CFURL, mediaBox: &defaultBox, nil))

    context.beginPDFPage([kCGPDFContextMediaBox: boxData(CGRect(x: 0, y: 0, width: 400, height: 500))] as CFDictionary)
    drawText("First page alpha", in: context, at: CGPoint(x: 40, y: 420))
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
    context.addRect(CGRect(x: 40, y: 300, width: 160, height: 60))
    context.fillPath()
    context.endPDFPage()

    context.beginPDFPage([kCGPDFContextMediaBox: boxData(CGRect(x: 0, y: 0, width: 300, height: 400))] as CFDictionary)
    drawText("Second page beta", in: context, at: CGPoint(x: 30, y: 340))
    context.draw(try makeTestImage(), in: CGRect(x: 30, y: 200, width: 120, height: 120))
    context.setURL(URL(string: "https://example.com/paper")! as CFURL,
                   for: CGRect(x: 30, y: 340, width: 200, height: 20))
    context.addDestination("chapter-two" as CFString, at: CGPoint(x: 30, y: 200))
    context.setDestination("chapter-two" as CFString, for: CGRect(x: 30, y: 150, width: 200, height: 20))
    context.endPDFPage()

    context.beginPDFPage([kCGPDFContextMediaBox: boxData(CGRect(x: 0, y: 0, width: 350, height: 450)),
                          "Rotate": 90] as CFDictionary)
    drawText("Third page gamma", in: context, at: CGPoint(x: 40, y: 380))
    context.setStrokeColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
    context.setLineWidth(3)
    context.addRect(CGRect(x: 40, y: 250, width: 200, height: 80))
    context.strokePath()
    context.endPDFPage()
    context.closePDF()
}

/// A one-page PDF with a line of text, as a Mac app writes it.
private func writeTextPDF(_ text: String, to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 400, height: 500)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    drawText(text, in: context, at: CGPoint(x: 40, y: 400))
    context.endPDFPage()
    context.closePDF()
}

/// Two pages: one with text drawn directly, and one whose text Quartz moved
/// into a form XObject by drawing the page inside a transparency layer.
private func writeFormReprint(to url: URL) throws {
    let inner = url.deletingLastPathComponent().appendingPathComponent("form-inner.pdf")
    try writeTextPDF("Form text alpha", to: inner)
    let innerPage = try #require(CGPDFDocument(inner as CFURL)?.page(at: 1))

    var box = CGRect(x: 0, y: 0, width: 400, height: 500)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    drawText("Direct page text", in: context, at: CGPoint(x: 40, y: 400))
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.drawPDFPage(innerPage)
    context.endTransparencyLayer()
    context.endPDFPage()
    context.closePDF()
}

/// The font resource named before the first `Tf` in a content stream.
private func firstFontName(in content: [UInt8]) -> String? {
    var lexer = PDFContentLexer(content)
    var lastName: String?
    while let token = lexer.next() {
        switch token.kind {
        case .name(let name): lastName = name
        case .op("Tf"): return lastName
        default: break
        }
    }
    return nil
}

/// A page whose /Contents is an array of two streams.
private func makeTwoStreamPDF() -> Data {
    var objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        "<< /Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] >>",
    ]
    for stream in ["0 0 1 rg", "1 0 0 rg"] {
        objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    return makeHandwrittenPDF(objects: objects, trailer: "")
}

/// A one-page document whose trailer names an encryption dictionary.
private func makeEncryptedPDF() -> Data {
    let stream = "0 0 1 rg 10 10 50 50 re f"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        "<< /Filter /Standard /V 1 /R 2 /O <\(String(repeating: "AA", count: 32))> "
            + "/U <\(String(repeating: "BB", count: 32))> /P -4 >>",
    ]
    let identifier = String(repeating: "00", count: 16)
    return makeHandwrittenPDF(objects: objects,
                              trailer: "/Encrypt 5 0 R /ID [<\(identifier)> <\(identifier)>]")
}

/// Assembles a PDF from object bodies written by hand, with a classic xref table.
private func makeHandwrittenPDF(objects: [String], trailer: String) -> Data {
    var out = Data("%PDF-1.7\n".utf8)
    var offsets: [Int] = []
    for (index, body) in objects.enumerated() {
        offsets.append(out.count)
        out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
    }
    let xref = out.count
    out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
        let digits = String(offset)
        out.append(Data((String(repeating: "0", count: 10 - digits.count) + digits + " 00000 n \n").utf8))
    }
    let extra = trailer.isEmpty ? "" : " " + trailer
    out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R\(extra) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return out
}

// MARK: - Drawing helpers

private func boxData(_ rect: CGRect) -> CFData {
    var rect = rect
    return Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
}

private func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat = 18) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}

private func makeTestImage() throws -> CGImage {
    let width = 24
    let height = 24
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for y in 0..<height {
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                 blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return try #require(context.makeImage())
}

// MARK: - Inspection helpers

private struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

/// Draws the page at 72 dpi on white, with the page rotation applied to the
/// bitmap size so the whole page is visible.
private func render(_ page: CGPDFPage, scale: CGFloat = 1) throws -> Bitmap {
    let box = page.getBoxRect(.mediaBox)
    let rotated = page.rotationAngle == 90 || page.rotationAngle == 270
    let width = Int(((rotated ? box.height : box.width) * scale).rounded())
    let height = Int(((rotated ? box.width : box.height) * scale).rounded())
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.scaleBy(x: scale, y: scale)
    context.drawPDFPage(page)
    let data = try #require(context.data)
    return Bitmap(width: width, height: height,
                  pixels: [UInt8](UnsafeRawBufferPointer(start: data, count: width * height * 4)))
}

/// Mean absolute difference per channel, between 0 and 255.
private func meanAbsoluteDifference(_ a: Bitmap, _ b: Bitmap) -> Double {
    guard a.width == b.width, a.height == b.height, a.pixels.count == b.pixels.count else { return .infinity }
    var totals = [0, 0, 0, 0]
    for index in a.pixels.indices {
        totals[index % 4] += abs(Int(a.pixels[index]) - Int(b.pixels[index]))
    }
    let samples = Double(a.pixels.count / 4)
    return totals.map { Double($0) / samples }.max() ?? 0
}

private func annotationCount(of page: CGPDFPage) -> Int {
    guard let dictionary = page.dictionary else { return 0 }
    var annotations: CGPDFArrayRef? = nil
    guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return 0 }
    return CGPDFArrayGetCount(annotations)
}

/// Counts page dictionaries in the serialized file. A duplicate page copy
/// would show up here, because every page dictionary carries "/Type /Page".
private func pageObjectCount(in data: Data) -> Int {
    let needle = Data("/Type /Page".utf8)
    let delimiters: Set<UInt8> = Set(" \n\r\t/>[]()<".utf8)
    var count = 0
    var index = data.startIndex
    while let range = data.range(of: needle, in: index..<data.endIndex) {
        // "/Type /Pages" is the page tree node, not a page.
        if range.upperBound < data.endIndex, delimiters.contains(data[range.upperBound]) { count += 1 }
        index = range.upperBound
    }
    return count
}
