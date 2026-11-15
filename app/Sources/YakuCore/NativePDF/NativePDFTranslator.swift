import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Translates a PDF with its layout kept, with Swift and system frameworks only.
///
/// For each page: interpret the content stream, group glyphs into paragraphs,
/// translate the paragraphs, then build two copies of the document with
/// text operators removed:
/// - the background copy loses every glyph of a translated paragraph;
/// - the formula copy loses only their non-formula glyphs, so it still holds
///   each inline formula exactly where it was.
/// The output page is the background page, the Japanese text typeset into the
/// paragraph boxes, and each inline formula drawn from the formula copy,
/// clipped to its box and moved to where the typesetter placed it.
public enum NativePDFTranslator {
    public struct Options: Sendable {
        /// 0-based page indices to translate. Nil means every page. Other pages are copied unchanged.
        public var pages: Set<Int>?
        /// How many paragraphs are sent to the engine at once.
        public var concurrency: Int

        public init(pages: Set<Int>? = nil, concurrency: Int = 4) {
            self.pages = pages
            self.concurrency = concurrency
        }
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case encrypted
        /// No page had text to translate: a scan, or text drawn as outlines.
        case noText
    }

    /// Source text in, translation out. Inline formulas arrive as `{v0}`, `{v1}`, ...
    public typealias Translate = @Sendable (String) async throws -> String
    /// Fraction done (0...1) and a stage name from `PDFStage`.
    public typealias Progress = @Sendable (Double, String) -> Void

    public struct Result: Sendable {
        public var paragraphs: Int
        public var formulaFallbacks: Int
        /// Paragraphs the model gave back as they were, left untouched.
        public var unchanged: Int
    }

    public static func translate(input: URL, monoOutput: URL, dualOutput: URL?, options: Options = Options(),
                                 translate: @escaping Translate, progress: @escaping Progress) async throws -> Result {
        progress(0, PDFStage.reading)
        guard let document = CGPDFDocument(input as CFURL) else { throw Failure.unreadable }
        guard !document.isEncrypted else { throw Failure.encrypted }

        // 1. Read every page we translate.
        let textSource = PDFDocument(url: input)
        var pages: [PageWork] = []
        for index in 0..<document.numberOfPages where options.pages?.contains(index) ?? true {
            try Task.checkCancellation()
            guard let page = document.page(at: index + 1) else { continue }
            pages.append(analyze(page, index: index, textSource: textSource?.page(at: index)))
            progress(0.1 * Double(pages.count) / Double(max(document.numberOfPages, 1)), PDFStage.layout)
        }

        // 2. Translate every paragraph that asks for it, a few at a time.
        let jobs = pages.enumerated().flatMap { pageOffset, work in
            work.paragraphs.indices.filter { work.paragraphs[$0].translate }.map { (pageOffset, $0) }
        }
        guard !jobs.isEmpty else { throw Failure.noText }
        let translations = try await translateAll(jobs: jobs, pages: pages, concurrency: options.concurrency,
                                                  translate: translate) { done in
            progress(0.1 + 0.8 * Double(done) / Double(max(jobs.count, 1)), PDFStage.translating)
        }
        // A paragraph the model returned unchanged (references, names, code)
        // keeps its original glyphs instead of being redrawn in another font.
        for ((pageOffset, paragraphIndex), pieces) in zip(jobs, translations) {
            if let pieces { pages[pageOffset].pieces[paragraphIndex] = pieces }
        }
        for offset in pages.indices { pages[offset].restoreDroppedText() }

        // 3. Strip the text and compose the output.
        progress(0.9, PDFStage.writing)
        try Task.checkCancellation()
        var backgroundEdits: [Int: [UInt8]] = [:]
        var formulaEdits: [Int: [UInt8]] = [:]
        var backgroundStreams: [UnsafeRawPointer: [UInt8]] = [:]
        var formulaStreams: [UnsafeRawPointer: [UInt8]] = [:]
        for work in pages {
            let stripped = work.stripped()
            backgroundEdits[work.index] = stripped.background
            formulaEdits[work.index] = stripped.formulas
            // A form drawn on several pages is stripped by the last page that
            // touches it. Its text is the same everywhere, so the result is too.
            backgroundStreams.merge(stripped.backgroundStreams) { $1 }
            formulaStreams.merge(stripped.formulaStreams) { $1 }
        }
        guard let background = CGPDFDocument(CGDataProvider(data: try PDFRewriter.rewrite(document, replacements: backgroundEdits, streamReplacements: backgroundStreams) as CFData)!),
              let formulaSource = CGPDFDocument(CGDataProvider(data: try PDFRewriter.rewrite(document, replacements: formulaEdits, streamReplacements: formulaStreams) as CFData)!)
        else { throw Failure.unreadable }

        try compose(document: document, background: background, formulaSource: formulaSource,
                    pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.index, $0) }), to: monoOutput)
        if let dualOutput, let translated = CGPDFDocument(monoOutput as CFURL) {
            try composeDual(original: document, translated: translated, to: dualOutput)
        }
        progress(1, PDFStage.writing)
        let fallbacks = translations.filter { $0?.isFallback ?? false }.count
        let unchanged = translations.filter { $0 == nil }.count
        return Result(paragraphs: jobs.count, formulaFallbacks: fallbacks, unchanged: unchanged)
    }

    // MARK: - Analysis

    struct Translated: Sendable {
        var pieces: [PDFFormulaPlaceholders.Piece]
        var formulas: [PDFTextSegment]
        var isFallback: Bool
    }

    struct PageWork: Sendable {
        var index: Int
        var mediaBox: CGRect
        var page: PDFPageContent
        var paragraphs: [PDFParagraph]
        var pieces: [Int: Translated] = [:]
        /// Address of each form stream this page draws, by stream index, for
        /// `PDFRewriter`'s stream replacements. A pointer is not `Sendable`, so
        /// the address travels as an integer.
        var formStreamKeys: [Int: UInt] = [:]

        /// The stripped page content and the stripped form streams of both copies.
        struct StrippedContents {
            var background: [UInt8]
            var formulas: [UInt8]
            var backgroundStreams: [UnsafeRawPointer: [UInt8]]
            var formulaStreams: [UnsafeRawPointer: [UInt8]]
        }

        /// Text operators go as a whole: one that draws mostly translated text is
        /// removed. When it also draws a paragraph that stays as it was (two figure
        /// labels in one operator, one translated), that paragraph is set again in
        /// its own words at its place, or it would vanish.
        mutating func restoreDroppedText() {
            var changed = true
            while changed {
                changed = false
                var translated = Set<Int>()
                for index in pieces.keys { translated.formUnion(paragraphs[index].glyphIndices) }
                var dropped = Set<Int>()
                for op in page.showOps where !op.glyphRange.isEmpty {
                    let count = op.glyphRange.filter { translated.contains($0) }.count
                    if count * 2 > op.glyphRange.count { dropped.formUnion(op.glyphRange) }
                }
                func visible(_ glyph: Int) -> Bool {
                    !page.glyphs[glyph].unicode.trimmingCharacters(in: .whitespaces).isEmpty
                }
                for (index, paragraph) in paragraphs.enumerated() where pieces[index] == nil {
                    guard paragraph.role != .formula,
                          paragraph.glyphIndices.contains(where: { dropped.contains($0) && visible($0) })
                    else { continue }
                    let text = PDFFormulaPlaceholders.plainSource(for: paragraph.segments)
                    guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { continue }
                    pieces[index] = Translated(pieces: [.text(text)], formulas: [], isFallback: true)
                    changed = true
                }
            }
        }

        /// Content without the translated paragraphs' glyphs, and content
        /// without only their non-formula glyphs.
        func stripped() -> StrippedContents {
            var translatedGlyphs = Set<Int>()
            var formulaGlyphs = Set<Int>()
            var movedFormulaBoxes: [CGRect] = []
            for (index, paragraph) in paragraphs.enumerated() where pieces[index] != nil {
                let formulas = paragraph.segments.compactMap { segment -> (box: CGRect, baseline: CGFloat)? in
                    if case .formula(_, let bounds, let baseline) = segment {
                        return (bounds.insetBy(dx: -0.5, dy: -0.5), baseline)
                    }
                    return nil
                }
                if !(pieces[index]?.isFallback ?? true) { movedFormulaBoxes += formulas.map(\.box) }
                for glyph in paragraph.glyphIndices {
                    translatedGlyphs.insert(glyph)
                    let item = page.glyphs[glyph]
                    let center = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
                    // A tall formula (a radical, a fraction) reaches over the next line's
                    // text, so a glyph counts only if it is a math glyph or sits on the
                    // formula's own line.
                    if formulas.contains(where: { formula in
                        formula.box.contains(center)
                            && (item.style.isMath || abs(item.origin.y - formula.baseline) <= item.fontSize * 0.8)
                    }) {
                        formulaGlyphs.insert(glyph)
                    }
                }
            }
            var dropAll = Set<Int>()
            var dropText = Set<Int>()
            for (opIndex, op) in page.showOps.enumerated() where !op.glyphRange.isEmpty {
                let glyphs = op.glyphRange
                let translated = glyphs.filter { translatedGlyphs.contains($0) }.count
                // An operator is removed when most of its glyphs belong to translated text.
                guard translated * 2 > glyphs.count else { continue }
                dropAll.insert(opIndex)
                // The formula copy keeps an operator that draws part of a formula (TeX
                // draws "= 8" as one operator) as long as its other glyphs fall outside
                // every formula box, because each formula is drawn by clipping this copy
                // to its box. A tall formula's box can reach over a neighbouring line.
                let drawsFormula = glyphs.contains { formulaGlyphs.contains($0) }
                let textInsideAFormulaBox = glyphs.contains { glyph in
                    guard !formulaGlyphs.contains(glyph) else { return false }
                    let box = page.glyphs[glyph].bounds
                    let center = CGPoint(x: box.midX, y: box.midY)
                    return movedFormulaBoxes.contains { $0.contains(center) }
                }
                if !drawsFormula || textInsideAFormulaBox { dropText.insert(opIndex) }
            }
            // Fraction bars and radical signs are paths. They move with their
            // formula, so the background must not keep them at the old place.
            let movedPaths = page.graphics.compactMap { graphic -> PDFStreamRange? in
                guard graphic.kind == .path, let range = graphic.byteRange,
                      movedFormulaBoxes.contains(where: { $0.contains(graphic.bounds) }) else { return nil }
                return PDFStreamRange(stream: graphic.stream, range: range)
            }
            let background = PDFContentStripper.removing(dropAll, from: page.streams,
                                                         showOps: page.showOps, paths: movedPaths)
            let formulas = PDFContentStripper.removing(dropText, from: page.streams, showOps: page.showOps)
            let pageContent = page.streams.first ?? []
            return StrippedContents(background: background[0] ?? pageContent,
                                    formulas: formulas[0] ?? pageContent,
                                    backgroundStreams: formReplacements(background),
                                    formulaStreams: formReplacements(formulas))
        }

        /// The changed form streams, keyed by the stream pointer the rewriter sees.
        private func formReplacements(_ streams: [Int: [UInt8]]) -> [UnsafeRawPointer: [UInt8]] {
            var replacements: [UnsafeRawPointer: [UInt8]] = [:]
            for (index, bytes) in streams {
                guard index != 0, let address = formStreamKeys[index],
                      let key = UnsafeRawPointer(bitPattern: address) else { continue }
                replacements[key] = bytes
            }
            return replacements
        }

        /// Only the page streams, for diagnostics that do not look at forms.
        func strippedContents() -> (background: [UInt8], formulas: [UInt8]) {
            let stripped = stripped()
            return (stripped.background, stripped.formulas)
        }
    }

    static func analyze(_ page: CGPDFPage, index: Int, textSource: PDFPage? = nil) -> PageWork {
        let mediaBox = page.getBoxRect(.mediaBox)
        let reading = PDFPageReader.read(page)
        var interpreted = reading.content
        if let textSource { PDFTextRecovery.fill(&interpreted.glyphs, from: textSource) }
        let paragraphs = keepingFigureLabels(
            PDFLayoutAnalyzer.paragraphs(glyphs: interpreted.glyphs, graphics: interpreted.graphics, pageBox: mediaBox),
            in: interpreted)
        return PageWork(index: index, mediaBox: mediaBox, page: interpreted, paragraphs: paragraphs,
                        formStreamKeys: reading.formStreams.mapValues {
                            UInt(bitPattern: unsafeBitCast($0, to: UnsafeRawPointer.self))
                        })
    }

    /// A figure drawn as a form XObject carries its labels inside the form, in
    /// type well below the body size. Those labels stay as they are, like the
    /// text the layout finds inside a figure drawn directly on the page. A page
    /// that is itself wrapped in a form keeps body-sized text, so it is translated.
    static func keepingFigureLabels(_ paragraphs: [PDFParagraph], in page: PDFPageContent) -> [PDFParagraph] {
        let sizes = page.glyphs.filter { $0.isUpright && !$0.unicode.isEmpty }.map(\.fontSize).sorted()
        guard !sizes.isEmpty else { return paragraphs }
        let bodySize = sizes[sizes.count / 2]
        func insideForm(_ glyph: Int) -> Bool {
            let op = page.glyphs[glyph].opIndex
            return page.showOps.indices.contains(op) && page.showOps[op].stream != 0
        }
        return paragraphs.map { paragraph in
            guard paragraph.translate, paragraph.fontSize < bodySize * 0.75,
                  !paragraph.glyphIndices.isEmpty, paragraph.glyphIndices.allSatisfy(insideForm) else { return paragraph }
            var label = paragraph
            label.translate = false
            label.role = .other
            return label
        }
    }

    static func inheritedDictionary(_ key: String, of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var current = page.dictionary
        while let dictionary = current {
            var found: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, key, &found) { return found }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    static func xobjectKinds(in resources: CGPDFDictionaryRef) -> [String: PDFGraphic.Kind] {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return [:] }
        final class Box: @unchecked Sendable { var kinds: [String: PDFGraphic.Kind] = [:] }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { key, value, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype {
                box.kinds[String(cString: key)] = String(cString: subtype) == "Form" ? .form : .image
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.kinds
    }

    // MARK: - Translation

    static func translateAll(jobs: [(Int, Int)], pages: [PageWork], concurrency: Int,
                             translate: @escaping Translate, done: @Sendable (Int) -> Void) async throws -> [Translated?] {
        var results = [Translated?](repeating: nil, count: jobs.count)
        try await withThrowingTaskGroup(of: (Int, Translated?).self) { group in
            var next = 0
            var finished = 0
            func addNext() {
                guard next < jobs.count else { return }
                let position = next
                let (pageOffset, paragraphIndex) = jobs[position]
                let segments = pages[pageOffset].paragraphs[paragraphIndex].segments
                group.addTask { (position, try await translateParagraph(segments, translate: translate)) }
                next += 1
            }
            for _ in 0..<max(concurrency, 1) { addNext() }
            while let (position, translated) = try await group.next() {
                results[position] = translated
                finished += 1
                done(finished)
                addNext()
            }
        }
        return results
    }

    /// Nil when the model gave the paragraph back unchanged.
    static func translateParagraph(_ segments: [PDFTextSegment], translate: Translate) async throws -> Translated? {
        let (source, formulas) = PDFFormulaPlaceholders.source(for: segments)
        let translation = try await translate(source)
        if CodeLikeText.isUnchanged(source: source, translation: translation) { return nil }
        if let pieces = PDFFormulaPlaceholders.pieces(from: translation, formulaCount: formulas.count) {
            return Translated(pieces: pieces, formulas: formulas, isFallback: false)
        }
        // The model lost or repeated a formula token: translate the formulas as text instead.
        let plainSource = PDFFormulaPlaceholders.plainSource(for: segments)
        let plain = try await translate(plainSource)
        if CodeLikeText.isUnchanged(source: plainSource, translation: plain) { return nil }
        return Translated(pieces: [.text(plain)], formulas: [], isFallback: true)
    }

    // MARK: - Output

    static func compose(document: CGPDFDocument, background: CGPDFDocument, formulaSource: CGPDFDocument,
                        pages: [Int: PageWork], to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, documentInfo(of: document)) else {
            throw Failure.unreadable
        }
        // Drawing a page does not carry its outline or annotations, so both are written again.
        // The output has the same pages in the same order, so page numbers stay valid.
        if let outline = document.outline { CGPDFContextSetOutline(context, outline) }
        let links = PDFLinkReader.links(in: document)
        var destinations: [Int: [(name: String, point: CGPoint)]] = [:]
        var destinationNames: [PDFLink.Target: String] = [:]
        // Each output page is the source page as a viewer shows it: its crop box,
        // turned by its /Rotate. Translations are drawn in the source page's space
        // through the same transform, and links are moved with it.
        let views = (0..<document.numberOfPages).map { document.page(at: $0 + 1).map(PageView.init) }
        for case .page(let target, let point) in links.values.joined().map(\.target)
        where destinationNames[.page(target, point)] == nil {
            let name = "perspica-\(target)-\(destinations[target, default: []].count)"
            destinationNames[.page(target, point)] = name
            destinations[target, default: []].append((name, point))
        }
        for index in 0..<document.numberOfPages {
            guard let page = background.page(at: index + 1), let view = views[index] else { continue }
            var mediaBox = CGRect(origin: .zero, size: view.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.saveGState()
            context.concatenate(view.transform)
            context.drawPDFPage(page)
            if let work = pages[index], let formulaPage = formulaSource.page(at: index + 1) {
                drawTranslations(work, formulaPage: formulaPage, in: context)
            }
            context.restoreGState()
            for destination in destinations[index] ?? [] {
                context.addDestination(destination.name as CFString, at: destination.point.applying(view.transform))
            }
            for link in links[index] ?? [] {
                let rect = link.rect.applying(view.transform)
                switch link.target {
                case .url(let target):
                    context.setURL(target as CFURL, for: rect)
                case .page:
                    if let name = destinationNames[link.target] { context.setDestination(name as CFString, for: rect) }
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// How a viewer shows a page: the crop box, rotated by /Rotate, placed at the origin.
    struct PageView {
        let size: CGSize
        let transform: CGAffineTransform

        init(_ page: CGPDFPage) {
            let crop = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            size = turned ? CGSize(width: crop.height, height: crop.width) : crop.size
            transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true)
        }
    }

    static func drawTranslations(_ work: PageWork, formulaPage: CGPDFPage, in context: CGContext) {
        // Every inline formula on the page, at its place in the source.
        let formulaBoxes: [(bounds: CGRect, baseline: CGFloat)] = work.pieces.values.flatMap(\.formulas)
            .compactMap { segment in
                guard case .formula(_, let bounds, let baseline) = segment else { return nil }
                return (bounds, baseline)
            }
        for (index, paragraph) in work.paragraphs.enumerated() {
            guard let translated = work.pieces[index] else { continue }
            var inputPieces: [PDFTypesetInput.Piece] = []
            for piece in translated.pieces {
                switch piece {
                case .text(let text):
                    inputPieces.append(.text(text))
                case .formula(let number):
                    guard case .formula(_, let bounds, let baseline) = translated.formulas[number] else { continue }
                    inputPieces.append(.inline(id: number, size: bounds.size, descent: max(0, baseline - bounds.minY)))
                }
            }
            let input = PDFTypesetInput(
                pieces: inputPieces,
                box: paragraph.bounds,
                maxBox: growthBox(for: index, in: work),
                fontSize: paragraph.fontSize,
                lineCount: paragraph.lineBounds.count,
                serif: paragraph.style.isSerif,
                bold: paragraph.style.isBold,
                alignment: isCentered(paragraph, in: work.mediaBox) ? .center : .natural,
                color: dominantColor(of: paragraph, in: work.page),
                firstLineIndent: (paragraph.lineBounds.first?.minX ?? paragraph.bounds.minX) - paragraph.bounds.minX
            )
            let result = PDFTypesetter.draw(input, in: context)
            for (number, placement) in result.inlinePlacements {
                guard number < translated.formulas.count,
                      case .formula(_, let bounds, let baseline) = translated.formulas[number] else { continue }
                context.saveGState()
                // A tall formula's box (a ∑ with its limits) can reach over an inline
                // formula on the line above, which the formula copy still draws. That
                // part of the box is left out, or the neighbour would be drawn twice.
                // The overlap belongs to the formula whose baseline is nearer to it.
                let offset = CGPoint(x: placement.minX - bounds.minX, y: placement.minY - bounds.minY)
                let overlaps: [CGRect] = formulaBoxes.compactMap { other in
                    guard other.bounds != bounds else { return nil }
                    let overlap = other.bounds.insetBy(dx: -1, dy: -1).intersection(bounds)
                    guard !overlap.isNull, overlap.width > 0, overlap.height > 0,
                          abs(overlap.midY - other.baseline) < abs(overlap.midY - baseline) else { return nil }
                    return overlap
                }
                let neighbours = mergedRects(overlaps)
                context.addRect(placement)
                for neighbour in neighbours {
                    context.addRect(neighbour.offsetBy(dx: offset.x, dy: offset.y))
                }
                context.clip(using: .evenOdd)
                context.translateBy(x: offset.x, y: offset.y)
                context.drawPDFPage(formulaPage)
                context.restoreGState()
            }
        }
    }

    /// Joins rectangles that overlap, so that an even-odd clip cuts each area out once.
    static func mergedRects(_ rects: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for rect in rects {
            var current = rect
            var changed = true
            while changed {
                changed = false
                if let index = merged.firstIndex(where: { $0.intersects(current) }) {
                    current = current.union(merged.remove(at: index))
                    changed = true
                }
            }
            merged.append(current)
        }
        return merged
    }

    /// Title, author, subject and keywords of the source, for the output's document info.
    static func documentInfo(of document: CGPDFDocument) -> CFDictionary? {
        guard let info = document.info else { return nil }
        var result: [String: String] = [:]
        let keys: [(String, CFString)] = [("Title", kCGPDFContextTitle), ("Author", kCGPDFContextAuthor),
                                          ("Subject", kCGPDFContextSubject), ("Keywords", kCGPDFContextKeywords)]
        for (key, contextKey) in keys {
            var value: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, key, &value), let value,
               let text = CGPDFStringCopyTextString(value) as String?, !text.isEmpty {
                result[contextKey as String] = text
            }
        }
        return result.isEmpty ? nil : result as CFDictionary
    }

    /// The most common glyph color, so a red notice stays red.
    static func dominantColor(of paragraph: PDFParagraph, in page: PDFPageContent) -> PDFColor {
        var counts: [PDFColor: Int] = [:]
        for index in paragraph.glyphIndices where page.glyphs.indices.contains(index) {
            counts[page.glyphs[index].color, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? .black
    }

    /// The space a paragraph may grow into: down to the nearest thing below it
    /// that overlaps it horizontally, or to the bottom margin.
    static func growthBox(for index: Int, in work: PageWork) -> CGRect {
        let box = work.paragraphs[index].bounds
        var floor = work.mediaBox.minY + 36
        let obstacles = work.paragraphs.enumerated().filter { $0.offset != index }.map(\.element.bounds)
            + work.page.graphics.map(\.bounds)
        for other in obstacles where other.maxY <= box.minY + 0.5 && other.maxX > box.minX && other.minX < box.maxX {
            floor = max(floor, other.maxY + 1)
        }
        floor = min(floor, box.minY)
        return CGRect(x: box.minX, y: floor, width: box.width, height: box.maxY - floor)
    }

    static func isCentered(_ paragraph: PDFParagraph, in mediaBox: CGRect) -> Bool {
        guard paragraph.role == .heading || paragraph.role == .caption, paragraph.lineBounds.count == 1 else { return false }
        return abs(paragraph.bounds.midX - mediaBox.midX) < 6 && paragraph.bounds.width < mediaBox.width * 0.7
    }

    /// Original on the left, translation on the right, on one wide page.
    static func composeDual(original: CGPDFDocument, translated: CGPDFDocument, to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { throw Failure.unreadable }
        for index in 1...max(original.numberOfPages, 1) {
            guard let left = original.page(at: index), let right = translated.page(at: index) else { continue }
            let leftView = PageView(left)
            let rightView = PageView(right)
            var mediaBox = CGRect(x: 0, y: 0, width: leftView.size.width + rightView.size.width,
                                  height: max(leftView.size.height, rightView.size.height))
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.saveGState()
            context.concatenate(leftView.transform)
            context.drawPDFPage(left)
            context.restoreGState()
            context.saveGState()
            context.translateBy(x: leftView.size.width, y: 0)
            context.concatenate(rightView.transform)
            context.drawPDFPage(right)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}
