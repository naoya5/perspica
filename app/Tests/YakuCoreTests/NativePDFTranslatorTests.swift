import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import YakuCore

/// End-to-end runs of the native PDF translator on the public Attention paper.
/// The fixture is not part of the repository: put it at `fixtures/attention.pdf`
/// in the repository root (https://arxiv.org/pdf/1706.03762v7). Tests skip without it.
@Suite struct NativePDFTranslatorTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../fixtures/attention.pdf").standardized

    static func outputDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stands in for the engine: Japanese text that keeps every formula token in order.
    @Sendable static func fakeTranslate(_ source: String) async throws -> String {
        let tokens = source.matches(of: /\{v\d+\}/).map { String($0.output) }
        return "これは訳文です" + tokens.map { "、\($0)" }.joined() + "。"
    }

    @Test func translatesEveryPageWithAFakeEngine() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else { return }
        let directory = try Self.outputDirectory()
        let mono = directory.appendingPathComponent("attention.fake.ja.pdf")
        let dual = directory.appendingPathComponent("attention.fake.ja.dual.pdf")
        let result = try await NativePDFTranslator.translate(
            input: Self.fixture, monoOutput: mono, dualOutput: dual,
            translate: Self.fakeTranslate, progress: { _, _ in })

        let translated = try #require(PDFDocument(url: mono))
        let original = try #require(PDFDocument(url: Self.fixture))
        #expect(translated.pageCount == original.pageCount)
        #expect(result.paragraphs > 100)
        #expect(result.formulaFallbacks == 0)
        // Body text of page 3 (index 2) is gone and the translation is there.
        let page = try #require(translated.page(at: 2)?.string)
        #expect(page.contains("これは訳文です"))
        #expect(!page.contains("The encoder is composed of a stack"))
        #expect(PDFDocument(url: dual)?.pageCount == original.pageCount)
        print("native pdf fake run: \(mono.path) paragraphs=\(result.paragraphs)")
    }

    @Test func linksSurviveTranslation() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else { return }
        let source = try #require(CGPDFDocument(Self.fixture as CFURL))
        let links = PDFLinkReader.links(in: source)
        let pageLinks = links.values.joined().filter { if case .page = $0.target { true } else { false } }
        #expect(pageLinks.count > 50)

        let mono = try Self.outputDirectory().appendingPathComponent("attention.links.pdf")
        _ = try await NativePDFTranslator.translate(
            input: Self.fixture, monoOutput: mono, dualOutput: nil,
            options: NativePDFTranslator.Options(pages: [1]),
            translate: Self.fakeTranslate, progress: { _, _ in })
        let output = try #require(PDFDocument(url: mono))
        let original = try #require(PDFDocument(url: Self.fixture))
        for index in [1, 4, 9] {
            let before = original.page(at: index)!.annotations.filter { $0.type == "Link" }.count
            let after = output.page(at: index)!.annotations.filter { $0.type == "Link" }.count
            #expect(after == before, "page \(index + 1)")
        }
        // A citation on page 2 still jumps to the reference list.
        let jump = output.page(at: 1)!.annotations.first { $0.destination != nil }
        let target = try #require(jump?.destination?.page)
        #expect(output.index(for: target) >= 9)
    }

    @Test func paragraphsReturnedUnchangedKeepTheirGlyphs() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else { return }
        let mono = try Self.outputDirectory().appendingPathComponent("attention.echo.pdf")
        let result = try await NativePDFTranslator.translate(
            input: Self.fixture, monoOutput: mono, dualOutput: nil,
            options: NativePDFTranslator.Options(pages: [11]),
            translate: { $0 }, progress: { _, _ in })
        #expect(result.paragraphs > 0)
        #expect(result.unchanged == result.paragraphs)
        let original = try #require(PDFDocument(url: Self.fixture)?.page(at: 11)?.string)
        let output = try #require(PDFDocument(url: mono)?.page(at: 11)?.string)
        #expect(output == original)
    }

    /// "VGG-19" and "34-layer plain" drawn by one operator: translating the second
    /// removes the operator, so the first is set again in its own words.
    @Test func textSharingARemovedOperatorIsSetAgain() {
        let style = PDFFontStyle(isSerif: true, isBold: false, isItalic: false, isMath: false, isMonospace: false)
        let labels = "VGG-19" + "34-layer plain"
        let glyphs = labels.enumerated().map { offset, character in
            PDFGlyph(unicode: String(character), origin: CGPoint(x: 80 + CGFloat(offset) * 5, y: 700),
                     advance: 5, fontSize: 8, fontName: "F1", style: style, opIndex: 0, renderMode: 0)
        }
        let content = PDFPageContent(glyphs: glyphs,
                                     showOps: [PDFShowOp(byteRange: 0..<10, op: "TJ", glyphRange: 0..<glyphs.count)],
                                     graphics: [])
        func paragraph(_ text: String, _ range: Range<Int>, translate: Bool) -> PDFParagraph {
            PDFParagraph(role: translate ? .body : .other, bounds: CGRect(x: 80, y: 700, width: 100, height: 8),
                         lineBounds: [], segments: [.text(text)], glyphIndices: Array(range),
                         fontSize: 8, style: style, translate: translate)
        }
        var work = NativePDFTranslator.PageWork(
            index: 0, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), page: content,
            paragraphs: [paragraph("VGG-19", 0..<6, translate: false),
                         paragraph("34-layer plain", 6..<glyphs.count, translate: true)])
        work.pieces[1] = .init(pieces: [.text("34層プレーン")], formulas: [], isFallback: false)
        work.restoreDroppedText()
        guard case .text(let restored)? = work.pieces[0]?.pieces.first else {
            Issue.record("VGG-19 was not set again")
            return
        }
        #expect(restored == "VGG-19")
    }

    @Test func aPDFWithoutTextFailsInsteadOfFinishingEmpty() async throws {
        let directory = try Self.outputDirectory()
        let scan = directory.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(scan as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.3, alpha: 1)
        context.fill(CGRect(x: 40, y: 40, width: 220, height: 320))
        context.endPDFPage()
        context.closePDF()
        await #expect(throws: NativePDFTranslator.Failure.noText) {
            _ = try await NativePDFTranslator.translate(
                input: scan, monoOutput: directory.appendingPathComponent("scan.ja.pdf"), dualOutput: nil,
                translate: Self.fakeTranslate, progress: { _, _ in })
        }
    }

    /// A one-page PDF with a paragraph drawn by Core Text, as a Mac app writes it.
    static func makeTextPDF(_ text: String, font: String, at url: URL, box: CGRect = CGRect(x: 0, y: 0, width: 420, height: 600),
                            crop: CGRect? = nil) throws {
        var mediaBox = box
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        var info: [String: Any] = [:]
        if var crop { info[kCGPDFContextCropBox as String] = Data(bytes: &crop, count: MemoryLayout<CGRect>.size) }
        context.beginPDFPage(info as CFDictionary)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, 11, nil),
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 60, y: 300, width: 300, height: 200), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
    }

    @Test func japaneseTextFromAMacAppIsReadAndReplaced() async throws {
        let directory = try Self.outputDirectory()
        let source = directory.appendingPathComponent("japanese.pdf")
        let japanese = "これは日本語の段落です。メニューバーの翻訳アプリで英語に訳します。文字の位置は元の段落の枠に合わせます。"
        try Self.makeTextPDF(japanese, font: "HiraMinProN-W3", at: source)
        let page = try #require(CGPDFDocument(source as CFURL)?.page(at: 1))
        let work = NativePDFTranslator.analyze(page, index: 0, textSource: PDFDocument(url: source)?.page(at: 0))
        let text = work.paragraphs.flatMap(\.segments).map { segment -> String in
            if case .text(let value) = segment { return value }
            return ""
        }.joined()
        #expect(text.contains("日本語の段落"))
        // Lines of Japanese join without an inserted space.
        #expect(!text.contains("訳 します") && !text.contains("の 段落"))

        let output = directory.appendingPathComponent("japanese.en.pdf")
        _ = try await NativePDFTranslator.translate(input: source, monoOutput: output, dualOutput: nil,
                                                     translate: { _ in "This paragraph was translated into English." },
                                                     progress: { _, _ in })
        let result = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(result.contains("translated into English"))
        #expect(!result.contains("日本語の段落"))
    }

    @Test func rotatedAndCroppedPagesKeepHowTheyLook() async throws {
        let directory = try Self.outputDirectory()
        let english = "This is a paragraph of English text that the translator replaces with a short Japanese sentence."
        let plain = directory.appendingPathComponent("plain.pdf")
        try Self.makeTextPDF(english, font: "Times-Roman", at: plain)
        let rotatedURL = directory.appendingPathComponent("rotated.pdf")
        let rotated = try #require(PDFDocument(url: plain))
        rotated.page(at: 0)?.rotation = 90
        #expect(rotated.write(to: rotatedURL))
        let croppedURL = directory.appendingPathComponent("cropped.pdf")
        try Self.makeTextPDF(english, font: "Times-Roman", at: croppedURL, crop: CGRect(x: 40, y: 250, width: 340, height: 300))

        for (input, size) in [(rotatedURL, CGSize(width: 600, height: 420)), (croppedURL, CGSize(width: 340, height: 300))] {
            let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".ja.pdf")
            _ = try await NativePDFTranslator.translate(input: input, monoOutput: output, dualOutput: nil,
                                                         translate: Self.fakeTranslate, progress: { _, _ in })
            let page = try #require(PDFDocument(url: output)?.page(at: 0))
            #expect(page.bounds(for: .mediaBox).size == size, "\(input.lastPathComponent)")
            #expect(page.string?.contains("これは訳文です") == true, "\(input.lastPathComponent)")
        }
    }

    @Test func outlineAndDocumentInfoSurvive() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else { return }
        let output = try Self.outputDirectory().appendingPathComponent("attention.outline.pdf")
        _ = try await NativePDFTranslator.translate(input: Self.fixture, monoOutput: output, dualOutput: nil,
                                                     options: NativePDFTranslator.Options(pages: [0]),
                                                     translate: Self.fakeTranslate, progress: { _, _ in })
        let original = try #require(PDFDocument(url: Self.fixture))
        let translated = try #require(PDFDocument(url: output))
        if let root = original.outlineRoot {
            #expect(translated.outlineRoot?.numberOfChildren == root.numberOfChildren)
        }
        let title = original.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if let title, !title.isEmpty {
            #expect(translated.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title)
        }
    }

    /// Runs against a real engine when `YAKU_TEST_ENGINE_URL` and `YAKU_TEST_ENGINE_KEY` are set.
    @Test func translatesWithTheRealEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["YAKU_TEST_ENGINE_URL"], let url = URL(string: urlString),
              let key = environment["YAKU_TEST_ENGINE_KEY"]
        else { return }
        // `YAKU_TEST_PDF` points the run at another document.
        let input = environment["YAKU_TEST_PDF"].map { URL(fileURLWithPath: $0) } ?? Self.fixture
        guard FileManager.default.fileExists(atPath: input.path) else { return }
        let client = EngineClient(baseURL: url, apiKey: key)
        let pages = environment["YAKU_TEST_PAGES"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let directory = try Self.outputDirectory()
        let mono = directory.appendingPathComponent("attention.engine.ja.pdf")
        let dual = directory.appendingPathComponent("attention.engine.ja.dual.pdf")
        let started = Date()
        let result = try await NativePDFTranslator.translate(
            input: input, monoOutput: mono, dualOutput: dual,
            options: NativePDFTranslator.Options(pages: pages),
            translate: { source in
                let chunks = TextChunker.chunks(from: source)
                var finished: [String] = []
                for chunk in chunks {
                    let request = PFML3.request(source: chunk.text, sourceLanguage: "en", targetLanguage: "ja",
                                                context: input.deletingPathExtension().lastPathComponent)
                    var buffer = ""
                    for try await piece in client.stream(request) { buffer += piece }
                    finished.append(TranslationCleanup.clean(buffer))
                }
                return TextChunker.join(finished, chunks: chunks)
            },
            progress: { _, _ in })
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "native pdf engine run: %.1fs paragraphs=%d fallbacks=%d -> %@",
                     seconds, result.paragraphs, result.formulaFallbacks, mono.path))
    }
}

/// Prints the analysis of one page when `YAKU_DEBUG_PAGE` is set (0-based), for tuning.
@Suite struct NativePDFDebugDump {
    @Test func dumpPage() throws {
        let input = ProcessInfo.processInfo.environment["YAKU_TEST_PDF"].map { URL(fileURLWithPath: $0) }
            ?? NativePDFTranslatorTests.fixture
        guard let value = ProcessInfo.processInfo.environment["YAKU_DEBUG_PAGE"], let index = Int(value),
              let document = CGPDFDocument(input as CFURL),
              let page = document.page(at: index + 1) else { return }
        let work = NativePDFTranslator.analyze(page, index: index)
        for (number, paragraph) in work.paragraphs.enumerated() {
            let text = paragraph.segments.map { segment -> String in
                switch segment {
                case .text(let value): value
                case .formula(let value, _, _): "{\(value)}"
                }
            }.joined()
            let b = paragraph.bounds
            print(String(format: "P%02d %@ %@ y=%.1f-%.1f x=%.1f-%.1f fs=%.1f lines=%d | ", number,
                         "\(paragraph.role)", paragraph.translate ? "T" : "-", b.minY, b.maxY, b.minX, b.maxX,
                         paragraph.fontSize, paragraph.lineBounds.count) + String(text.prefix(110)))
            guard ProcessInfo.processInfo.environment["YAKU_DEBUG_FORMULAS"] != nil else { continue }
            for case .formula(let value, let bounds, let baseline) in paragraph.segments {
                let inside = paragraph.glyphIndices.map { work.page.glyphs[$0] }
                    .filter { bounds.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
                    .map(\.unicode).joined()
                print(String(format: "    formula %@ x=%.1f-%.1f y=%.1f-%.1f base=%.1f glyphs=%@",
                             value, bounds.minX, bounds.maxX, bounds.minY, bounds.maxY, baseline, inside))
            }
        }
    }
}

@Suite struct NativePDFOpDebug {
    /// `YAKU_DEBUG_OPS=<page>`: lists the show operators the formula copy keeps on that page.
    @Test func dumpKeptOps() throws {
        guard let value = ProcessInfo.processInfo.environment["YAKU_DEBUG_OPS"], let index = Int(value),
              let document = CGPDFDocument(NativePDFTranslatorTests.fixture as CFURL),
              let page = document.page(at: index + 1) else { return }
        var work = NativePDFTranslator.analyze(page, index: index)
        for (number, paragraph) in work.paragraphs.enumerated() where paragraph.translate {
            work.pieces[number] = .init(pieces: [], formulas: [], isFallback: false)
        }
        let (_, formulas) = work.strippedContents()
        let kept = PDFContentInterpreter.interpret(formulas, fonts: [:]).showOps.count
        print("formula copy keeps \(kept) of \(work.page.showOps.count) show ops")
        for (opIndex, op) in work.page.showOps.enumerated() {
            let text = op.glyphRange.map { work.page.glyphs[$0].unicode }.joined()
            let y = op.glyphRange.first.map { work.page.glyphs[$0].origin.y } ?? 0
            if y > 385, y < 410 { print(String(format: "op %d y=%.1f %@", opIndex, y, text)) }
        }
    }
}

@Suite struct NativePDFFontDebug {
    /// `YAKU_DEBUG_FONTS=<page>` with `YAKU_TEST_PDF`: prints each font and how "0123456789" style codes decode.
    @Test func dumpFonts() throws {
        guard let value = ProcessInfo.processInfo.environment["YAKU_DEBUG_FONTS"], let index = Int(value),
              let path = ProcessInfo.processInfo.environment["YAKU_TEST_PDF"],
              let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
              let page = document.page(at: index + 1),
              let resources = NativePDFTranslator.inheritedDictionary("Resources", of: page) else { return }
        for (name, description) in PDFFontReader.fonts(in: resources).sorted(by: { $0.key < $1.key }) {
            let decoded = PDFFontDecoder(description).decode(Array(48...57).map(UInt8.init)).map(\.unicode).joined()
            print("font \(name) \(description.baseFont) kind=\(description.kind) enc=\(description.baseEncoding ?? "-") diffs=\(description.differences.count) tounicode=\(description.toUnicode != nil) digits=[\(decoded)] diff48=\(description.differences[48] ?? "-")")
        }
    }
}
