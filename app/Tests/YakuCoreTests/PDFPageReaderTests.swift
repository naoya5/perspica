import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import YakuCore

private let attentionFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // PDFPageReaderTests.swift
    .deletingLastPathComponent() // YakuCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // app
    .appendingPathComponent("fixtures/attention.pdf")

@Suite("PDFPageReaderTests")
struct PDFPageReaderTests {
    // MARK: - Handwritten forms

    @Test("a form with its own font and matrix places glyphs in page space")
    func formMatrixAndFont() throws {
        let url = try writeTemporary(makeFormPDF(pageContent: "q 1 0 0 1 0 0 cm /Fm1 Do Q",
                                                 formContent: "BT /F2 10 Tf 0 0 Td (AB) Tj ET",
                                                 formResources: "<< /Font << /F2 6 0 R >> >>"),
                                     name: "form-matrix.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let reading = PDFPageReader.read(try #require(document.page(at: 1)))

        #expect(reading.content.streams.count == 2)
        #expect(reading.formStreams[1] != nil)
        #expect(reading.content.showOps.map(\.stream) == [1])
        let glyphs = reading.content.glyphs
        #expect(glyphs.map(\.unicode) == ["A", "B"])
        // The form's /Matrix moves form space by (10, 20) and its own font
        // decodes the codes, so the glyphs land at the form's place on the page.
        #expect(abs(glyphs[0].origin.x - 10) < 0.01)
        #expect(abs(glyphs[0].origin.y - 20) < 0.01)
        #expect(glyphs[1].origin.y == glyphs[0].origin.y)
        #expect(glyphs[1].origin.x > glyphs[0].origin.x)
        #expect(glyphs[0].fontName == "Helvetica")
    }

    @Test("a form drawn twice keeps one stream index and both placements")
    func formDrawnTwice() throws {
        let url = try writeTemporary(makeFormPDF(pageContent: "q 1 0 0 1 0 0 cm /Fm1 Do Q q 1 0 0 1 0 100 cm /Fm1 Do Q",
                                                 formContent: "BT /F2 10 Tf 0 0 Td (A) Tj ET",
                                                 formResources: "<< /Font << /F2 6 0 R >> >>"),
                                     name: "form-twice.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let reading = PDFPageReader.read(try #require(document.page(at: 1)))

        #expect(reading.content.streams.count == 2)
        #expect(reading.content.showOps.map(\.stream) == [1, 1])
        let origins = reading.content.glyphs.map(\.origin)
        #expect(origins.count == 2)
        #expect(abs(origins[0].y - 20) < 0.01)
        #expect(abs(origins[1].y - 120) < 0.01)
    }

    @Test("a form that draws itself is read once instead of hanging")
    func formCycle() throws {
        let url = try writeTemporary(makeFormPDF(pageContent: "/Fm1 Do",
                                                 formContent: "/Fm1 Do BT /F2 10 Tf 0 0 Td (A) Tj ET",
                                                 formResources: "<< /Font << /F2 6 0 R >> /XObject << /Fm1 5 0 R >> >>"),
                                     name: "form-cycle.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let reading = PDFPageReader.read(try #require(document.page(at: 1)))

        #expect(reading.content.glyphs.map(\.unicode) == ["A"])
        #expect(reading.content.showOps.map(\.stream) == [1])
    }

    @Test("a form inside a form gets its own stream and both matrices apply")
    func nestedForms() throws {
        let pageContent = "/Fm1 Do"
        let outerContent = "/Fm2 Do"
        let innerContent = "BT /F2 10 Tf 0 0 Td (N) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(pageContent.utf8.count) >>\nstream\n\(pageContent)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Matrix [1 0 0 1 5 5] "
                + "/Resources << /XObject << /Fm2 7 0 R >> >> /Length \(outerContent.utf8.count) >>\nstream\n\(outerContent)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 0 50] "
                + "/Resources << /Font << /F2 6 0 R >> >> /Length \(innerContent.utf8.count) >>\nstream\n\(innerContent)\nendstream",
        ]
        let url = try writeTemporary(handwrittenPDF(objects: objects), name: "form-nested.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let reading = PDFPageReader.read(try #require(document.page(at: 1)))

        #expect(reading.content.streams.count == 3)
        #expect(reading.formStreams[1] != nil)
        #expect(reading.formStreams[2] != nil)
        #expect(reading.content.showOps.map(\.stream) == [2])
        let origin = try #require(reading.content.glyphs.first?.origin)
        #expect(abs(origin.x - 5) < 0.01)
        #expect(abs(origin.y - 55) < 0.01)
    }

    // MARK: - Quartz re-prints

    @Test("a page whose text Quartz moved into a form reads at the same places")
    func quartzReprint() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("plain.pdf")
        try writeTextPDF("Reprinted paragraph text", to: plain)
        let reprinted = directory.appendingPathComponent("reprinted.pdf")
        try writeReprint(of: plain, to: reprinted)

        let plainPage = try #require(CGPDFDocument(plain as CFURL)?.page(at: 1))
        let reprintedPage = try #require(CGPDFDocument(reprinted as CFURL)?.page(at: 1))
        let direct = PDFPageReader.read(plainPage)
        let inside = PDFPageReader.read(reprintedPage)

        // Quartz writes a drawn page as a form XObject, so the page stream only
        // holds the Do and every glyph comes from the form.
        #expect(inside.content.streams.count == 2)
        #expect(!inside.content.showOps.isEmpty)
        #expect(inside.content.showOps.allSatisfy { $0.stream == 1 })
        #expect(direct.content.glyphs.count == inside.content.glyphs.count)
        #expect(direct.content.glyphs.map(\.unicode) == inside.content.glyphs.map(\.unicode))
        for (expected, actual) in zip(direct.content.glyphs, inside.content.glyphs) {
            #expect(abs(expected.origin.x - actual.origin.x) < 0.01)
            #expect(abs(expected.origin.y - actual.origin.y) < 0.01)
            #expect(abs(expected.fontSize - actual.fontSize) < 0.01)
        }
    }

    // MARK: - End to end

    @Test("a re-printed page whose text is inside a form is translated",
          .enabled(if: FileManager.default.fileExists(atPath: attentionFixture.path)))
    func translatesTextInsideAForm() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reprinted = directory.appendingPathComponent("attention-page3-reprint.pdf")
        try writeReprint(of: attentionFixture, page: 3, to: reprinted)

        let reprint = try #require(CGPDFDocument(reprinted as CFURL))
        let reading = PDFPageReader.read(try #require(reprint.page(at: 1)))
        #expect(reading.content.streams.count > 1)
        #expect(reading.content.showOps.contains { $0.stream != 0 })
        #expect(reading.content.glyphs.map(\.unicode).joined().contains("encoder"))

        let output = directory.appendingPathComponent("attention-page3-reprint.ja.pdf")
        let result = try await NativePDFTranslator.translate(
            input: reprinted, monoOutput: output, dualOutput: nil,
            translate: { source in
                let tokens = source.matches(of: /\{v\d+\}/).map { String($0.output) }
                return "これは訳文です" + tokens.map { "、\($0)" }.joined() + "。"
            },
            progress: { _, _ in })
        #expect(result.paragraphs > 0)

        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("これは訳文です"))
        #expect(!text.contains("The encoder is composed of a stack"))
    }
}

// MARK: - Documents

/// One page whose content draws `/Fm1`, and a form whose content has the text.
private func makeFormPDF(pageContent: String, formContent: String, formResources: String) -> Data {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] "
            + "/Resources << /Font << /F1 6 0 R >> /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(pageContent.utf8.count) >>\nstream\n\(pageContent)\nendstream",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Matrix [1 0 0 1 10 20] "
            + "/Resources \(formResources) /Length \(formContent.utf8.count) >>\nstream\n\(formContent)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    return handwrittenPDF(objects: objects)
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

/// Draws `source` into a new context. A transparency layer makes Quartz write
/// the drawn page as a form XObject, which is the shape this reader is for.
private func writeReprint(of source: URL, page: Int = 1, to url: URL) throws {
    let document = try #require(CGPDFDocument(source as CFURL))
    let sourcePage = try #require(document.page(at: page))
    var box = sourcePage.getBoxRect(.mediaBox)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.drawPDFPage(sourcePage)
    context.endTransparencyLayer()
    context.endPDFPage()
    context.closePDF()
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

/// Assembles a PDF from object bodies written by hand, with a classic xref table.
private func handwrittenPDF(objects: [String]) -> Data {
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
    out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return out
}

// MARK: - Files

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PDFPageReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTemporary(_ data: Data, name: String) throws -> URL {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}
