import CoreGraphics
import Foundation

/// A form XObject the interpreter can draw.
///
/// The content stream only names a form (`/Fm0 Do`), so the caller has to look
/// the name up in the resources and hand the interpreter the form's bytes.
/// Not `Sendable`: a resolver reads CoreGraphics stream references.
public struct PDFFormSource {
    /// Index of the form's content stream in `PDFPageContent.streams`.
    public var index: Int
    /// The form's decoded content stream.
    public var content: [UInt8]
    /// The form's /Matrix, which maps form space to the space of the `Do` that drew it.
    public var matrix: CGAffineTransform
    /// Font decoders of the form's own /Resources /Font.
    public var fonts: [String: any PDFCharDecoding]
    /// What the form's own XObject resources draw.
    public var xobjectKinds: [String: PDFGraphic.Kind]
    /// Resolves the forms this form draws, in its own resources. Nil when the
    /// form has no resources of its own, so the parent's resolver is used.
    public var resolver: (any PDFFormResolving)?

    public init(index: Int, content: [UInt8], matrix: CGAffineTransform = .identity,
                fonts: [String: any PDFCharDecoding] = [:],
                xobjectKinds: [String: PDFGraphic.Kind] = [:],
                resolver: (any PDFFormResolving)? = nil) {
        self.index = index
        self.content = content
        self.matrix = matrix
        self.fonts = fonts
        self.xobjectKinds = xobjectKinds
        self.resolver = resolver
    }
}

/// Resolves the form a `Do` operand names, within one resource scope.
public protocol PDFFormResolving {
    /// The form `name` draws, or nil when the name is not a form (an image, or unknown).
    func form(named name: String) -> PDFFormSource?
}

/// Reads a page content stream into glyphs, text-showing operators and graphics.
public enum PDFContentInterpreter {
    /// - Parameters:
    ///   - content: The decoded, concatenated content streams of one page.
    ///   - fonts: Decoders keyed by font resource name (the operand of `Tf`, without the slash).
    ///   - xobjectKinds: What each XObject resource name draws. A `Do` operand that is not
    ///     listed is assumed to be an image, because the content stream alone cannot tell.
    ///   - resolver: Resolves form XObjects so their content is interpreted too. Without it
    ///     a form is only recorded as a graphic, which is all a content stream alone allows.
    public static func interpret(
        _ content: [UInt8],
        fonts: [String: any PDFCharDecoding],
        xobjectKinds: [String: PDFGraphic.Kind] = [:],
        resolver: (any PDFFormResolving)? = nil
    ) -> PDFPageContent {
        var interpreter = Interpreter(fonts: fonts, xobjectKinds: xobjectKinds, resolver: resolver)
        interpreter.run(content)
        return PDFPageContent(glyphs: interpreter.glyphs,
                              showOps: interpreter.showOps,
                              graphics: interpreter.graphics,
                              streams: [content])
    }
}

/// A byte range inside one content stream of a page.
public struct PDFStreamRange: Sendable, Equatable {
    /// Index into `PDFPageContent.streams`.
    public var stream: Int
    public var range: Range<Int>

    public init(stream: Int, range: Range<Int>) {
        self.stream = stream
        self.range = range
    }
}

/// Removes text-showing operators from a content stream.
public enum PDFContentStripper {
    /// Returns `content` with the show operators at `ops` (indices into `showOps`) removed.
    /// Every other byte is kept exactly as it was.
    ///
    /// `'` also moves to the next line, and `"` sets word and character spacing before
    /// doing so. Those side effects are kept, otherwise the remaining glyphs would move.
    public static func removing(_ ops: Set<Int>, from content: [UInt8], showOps: [PDFShowOp]) -> [UInt8] {
        removing(ops, from: content, showOps: showOps, paths: [])
    }

    /// Also removes painted paths, given by their `PDFGraphic.byteRange`.
    public static func removing(_ ops: Set<Int>, from content: [UInt8], showOps: [PDFShowOp],
                                paths: [Range<Int>]) -> [UInt8] {
        let cuts = ops
            .filter { showOps.indices.contains($0) }
            .map { (range: showOps[$0].byteRange, op: Optional(showOps[$0])) }
            + paths.map { (range: $0, op: nil) }

        var out: [UInt8] = []
        out.reserveCapacity(content.count)
        var cursor = 0
        for cut in cuts.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let range = cut.range
            guard range.lowerBound >= cursor, range.upperBound <= content.count else { continue }
            out.append(contentsOf: content[cursor..<range.lowerBound])
            if let op = cut.op { out.append(contentsOf: replacement(for: op, in: content)) }
            cursor = range.upperBound
        }
        out.append(contentsOf: content[cursor...])
        return out
    }

    /// Removes the operators and paths from every stream they belong to.
    ///
    /// Each show operator and path carries the index of its stream, so a page
    /// whose text lives in a form XObject is stripped in the form's own bytes.
    /// - Returns: The new bytes of every stream that changed, keyed by stream index.
    public static func removing(_ ops: Set<Int>, from streams: [[UInt8]], showOps: [PDFShowOp],
                                paths: [PDFStreamRange] = []) -> [Int: [UInt8]] {
        var touched = Set(paths.map(\.stream))
        for index in ops where showOps.indices.contains(index) {
            touched.insert(showOps[index].stream)
        }
        var changed: [Int: [UInt8]] = [:]
        for stream in touched where streams.indices.contains(stream) {
            let streamOps = ops.filter { showOps.indices.contains($0) && showOps[$0].stream == stream }
            let streamPaths = paths.filter { $0.stream == stream }.map(\.range)
            let bytes = removing(streamOps, from: streams[stream], showOps: showOps, paths: streamPaths)
            if bytes != streams[stream] { changed[stream] = bytes }
        }
        return changed
    }

    private static func replacement(for op: PDFShowOp, in content: [UInt8]) -> [UInt8] {
        switch op.op {
        case "'":
            return Array("T*".utf8)
        case "\"":
            // aw ac " must become aw Tw ac Tc T* so the line move and the
            // spacing change survive the removal of the text itself.
            let numbers = numbers(in: content, range: op.byteRange)
            let wordSpacing = numbers.count > 0 ? format(numbers[0]) : "0"
            let charSpacing = numbers.count > 1 ? format(numbers[1]) : "0"
            return Array("\(wordSpacing) Tw \(charSpacing) Tc T*".utf8)
        default:
            return []
        }
    }

    private static func numbers(in content: [UInt8], range: Range<Int>) -> [Double] {
        var lexer = PDFContentLexer(Array(content[range]))
        var values: [Double] = []
        while let token = lexer.next() {
            if case .number(let value) = token.kind { values.append(value) }
        }
        return values
    }

    /// PDF has no exponent notation, so a fixed decimal form is the safe choice.
    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Interpreter state

private struct TextState {
    var charSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var horizontalScaling: CGFloat = 1
    var leading: CGFloat = 0
    var fontName = ""
    var fontSize: CGFloat = 0
    var rise: CGFloat = 0
    var renderMode = 0
}

private struct GraphicsState {
    var ctm: CGAffineTransform = .identity
    var text = TextState()
    var fillColor = PDFColor.black
}

/// Used when a `Tf` name has no decoder: one byte per code, no Unicode, half-em widths.
private struct FallbackFontDecoder: PDFCharDecoding {
    let fontName: String

    var style: PDFFontStyle {
        PDFFontStyle(isSerif: false, isBold: false, isItalic: false, isMath: false, isMonospace: false)
    }

    func decode(_ bytes: [UInt8]) -> [PDFDecodedChar] {
        bytes.map { PDFDecodedChar(code: Int($0), unicode: "", width: 0.5, isWordSpace: $0 == 32) }
    }
}

private enum ShowItem {
    case string([UInt8])
    case adjust(CGFloat)
}

private struct Interpreter {
    var fonts: [String: any PDFCharDecoding]
    var xobjectKinds: [String: PDFGraphic.Kind]
    var resolver: (any PDFFormResolving)?
    /// Index of the content stream being read, for the operators it records.
    var stream = 0
    /// Form stream indices currently being drawn, to stop a form that draws itself.
    var formStack: [Int] = []

    var gstate = GraphicsState()
    var savedStates: [GraphicsState] = []
    var textMatrix: CGAffineTransform = .identity
    var textLineMatrix: CGAffineTransform = .identity

    var glyphs: [PDFGlyph] = []
    var showOps: [PDFShowOp] = []
    var graphics: [PDFGraphic] = []

    var operands: [PDFContentToken] = []
    var operandStart: Int?
    var pathPoints: [CGPoint] = []
    /// Start of the first operator of the current path, for its byte range.
    var pathStart: Int?

    init(fonts: [String: any PDFCharDecoding], xobjectKinds: [String: PDFGraphic.Kind],
         resolver: (any PDFFormResolving)?) {
        self.fonts = fonts
        self.xobjectKinds = xobjectKinds
        self.resolver = resolver
    }

    mutating func run(_ content: [UInt8]) {
        // A form's content is a stream of its own: operands and paths cannot
        // span the boundary, so the state of the stream that drew it is set
        // aside until the form has been read.
        let savedOperands = operands
        let savedOperandStart = operandStart
        let savedPoints = pathPoints
        let savedPathStart = pathStart
        operands = []
        operandStart = nil
        pathPoints = []
        pathStart = nil
        defer {
            operands = savedOperands
            operandStart = savedOperandStart
            pathPoints = savedPoints
            pathStart = savedPathStart
        }

        var lexer = PDFContentLexer(content)
        while let token = lexer.next() {
            switch token.kind {
            case .op(let name):
                let range = (operandStart ?? token.start)..<token.end
                perform(name, range: range)
                operands.removeAll(keepingCapacity: true)
                operandStart = nil
            case .inlineImage:
                addXObject(.image)
                operands.removeAll(keepingCapacity: true)
                operandStart = nil
            default:
                if operandStart == nil { operandStart = token.start }
                operands.append(token)
            }
        }
    }

    // MARK: - Operators

    private mutating func perform(_ name: String, range: Range<Int>) {
        switch name {
        case "q":
            savedStates.append(gstate)
        case "Q":
            if let saved = savedStates.popLast() { gstate = saved }
        case "cm":
            if let matrix = matrixOperand() {
                gstate.ctm = matrix.concatenating(gstate.ctm)
            }
        case "BT":
            textMatrix = .identity
            textLineMatrix = .identity
        case "ET":
            break
        case "Td":
            if let (tx, ty) = pairOperand() { moveLine(tx: tx, ty: ty) }
        case "TD":
            if let (tx, ty) = pairOperand() {
                gstate.text.leading = -ty
                moveLine(tx: tx, ty: ty)
            }
        case "Tm":
            if let matrix = matrixOperand() {
                textMatrix = matrix
                textLineMatrix = matrix
            }
        case "T*":
            moveLine(tx: 0, ty: -gstate.text.leading)
        case "Tc":
            if let value = numberOperands.first { gstate.text.charSpacing = value }
        case "Tw":
            if let value = numberOperands.first { gstate.text.wordSpacing = value }
        case "Tz":
            if let value = numberOperands.first { gstate.text.horizontalScaling = value / 100 }
        case "TL":
            if let value = numberOperands.first { gstate.text.leading = value }
        case "Tf":
            if let font = nameOperand { gstate.text.fontName = font }
            if let size = numberOperands.last { gstate.text.fontSize = size }
        case "Tr":
            // Render modes are small integers; a wild value must not trap the
            // conversion, so only a finite value in range is accepted.
            if let value = numberOperands.first, value.isFinite, value >= 0, value <= 255 {
                gstate.text.renderMode = Int(value)
            }
        case "Ts":
            if let value = numberOperands.first { gstate.text.rise = value }
        case "Tj", "TJ":
            show(showItems(), op: name, range: range)
        case "'":
            moveLine(tx: 0, ty: -gstate.text.leading)
            show(showItems(), op: name, range: range)
        case "\"":
            let numbers = numberOperands
            if numbers.count >= 2 {
                gstate.text.wordSpacing = numbers[0]
                gstate.text.charSpacing = numbers[1]
            }
            moveLine(tx: 0, ty: -gstate.text.leading)
            show(showItems(), op: name, range: range)
        case "g", "rg", "k":
            if let color = Self.deviceColor(numberOperands) { gstate.fillColor = color }
        case "sc", "scn":
            // Pattern names and other color spaces with more components are not followed;
            // one, three or four numbers are read as gray, RGB or CMYK.
            if let color = Self.deviceColor(numberOperands) { gstate.fillColor = color }
        case "cs":
            // The initial color of every device and most other spaces is black.
            gstate.fillColor = .black
        case "Do":
            if let name = nameOperand {
                let kind = xobjectKinds[name] ?? .image
                addXObject(kind)
                // The form's own content is drawn at this point of the stream,
                // so its glyphs belong to the page exactly like the page's own.
                if kind == .form, let source = resolver?.form(named: name) { drawForm(source) }
            }
        case "m", "l", "c", "v", "y", "re", "h", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
            performPath(name, range: range)
        default:
            break
        }
    }

    private mutating func performPath(_ name: String, range: Range<Int>) {
        if pathStart == nil { pathStart = range.lowerBound }
        switch name {
        case "m", "l":
            if let (x, y) = pairOperand() { pathPoints.append(CGPoint(x: x, y: y)) }
        case "c":
            if let numbers = lastNumbers(6) {
                for index in stride(from: 0, to: 6, by: 2) {
                    pathPoints.append(CGPoint(x: numbers[index], y: numbers[index + 1]))
                }
            }
        case "v", "y":
            // The first control point of `v` is the current point, which is
            // already part of the path; the remaining points are the operands.
            if let numbers = lastNumbers(4) {
                pathPoints.append(CGPoint(x: numbers[0], y: numbers[1]))
                pathPoints.append(CGPoint(x: numbers[2], y: numbers[3]))
            }
        case "re":
            if let numbers = lastNumbers(4) {
                let x = numbers[0], y = numbers[1], width = numbers[2], height = numbers[3]
                pathPoints.append(contentsOf: [
                    CGPoint(x: x, y: y),
                    CGPoint(x: x + width, y: y),
                    CGPoint(x: x + width, y: y + height),
                    CGPoint(x: x, y: y + height),
                ])
            }
        case "h":
            // The closing line ends at the subpath start, which is recorded already.
            break
        case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
            paintPath(byteRange: (pathStart ?? range.lowerBound)..<range.upperBound)
            pathStart = nil
        case "n":
            pathPoints.removeAll(keepingCapacity: true)
            pathStart = nil
        default:
            break
        }
    }

    // MARK: - Operands

    private var numberOperands: [CGFloat] {
        operands.compactMap {
            if case .number(let value) = $0.kind { return CGFloat(value) }
            return nil
        }
    }

    private var nameOperand: String? {
        for token in operands {
            if case .name(let name) = token.kind { return name }
        }
        return nil
    }

    private func lastNumbers(_ count: Int) -> [CGFloat]? {
        let numbers = numberOperands
        guard numbers.count >= count else { return nil }
        return Array(numbers.suffix(count))
    }

    private func pairOperand() -> (CGFloat, CGFloat)? {
        guard let numbers = lastNumbers(2) else { return nil }
        return (numbers[0], numbers[1])
    }

    private func matrixOperand() -> CGAffineTransform? {
        guard let numbers = lastNumbers(6) else { return nil }
        return CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                 d: numbers[3], tx: numbers[4], ty: numbers[5])
    }

    private func showItems() -> [ShowItem] {
        var items: [ShowItem] = []
        var inArray = false
        for token in operands {
            switch token.kind {
            case .arrayStart:
                inArray = true
            case .arrayEnd:
                inArray = false
            case .string(let bytes):
                items.append(.string(bytes))
            case .number(let value) where inArray:
                items.append(.adjust(CGFloat(value)))
            default:
                break
            }
        }
        return items
    }

    // MARK: - Text

    private mutating func moveLine(tx: CGFloat, ty: CGFloat) {
        textLineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(textLineMatrix)
        textMatrix = textLineMatrix
    }

    private mutating func show(_ items: [ShowItem], op: String, range: Range<Int>) {
        let opIndex = showOps.count
        let glyphStart = glyphs.count
        for item in items {
            switch item {
            case .adjust(let amount):
                // A TJ number moves the pen back by n/1000 em, without spacing.
                let tx = -amount / 1000 * gstate.text.fontSize * gstate.text.horizontalScaling
                textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
            case .string(let bytes):
                let decoder = fonts[gstate.text.fontName] ?? FallbackFontDecoder(fontName: gstate.text.fontName)
                for char in decoder.decode(bytes) {
                    appendGlyph(char, decoder: decoder, opIndex: opIndex)
                }
            }
        }
        showOps.append(PDFShowOp(byteRange: range, op: op, glyphRange: glyphStart..<glyphs.count,
                                 stream: stream))
    }

    private mutating func appendGlyph(_ char: PDFDecodedChar, decoder: any PDFCharDecoding, opIndex: Int) {
        let text = gstate.text
        let combined = textMatrix.concatenating(gstate.ctm)
        // Trm = [Tfs*Th 0 0; 0 Tfs 0; 0 Ts 1] x Tm x CTM.
        let scale = CGAffineTransform(a: text.fontSize * text.horizontalScaling, b: 0,
                                      c: 0, d: text.fontSize, tx: 0, ty: text.rise)
        let origin = CGPoint.zero.applying(scale.concatenating(combined))

        let linear = CGAffineTransform(a: combined.a, b: combined.b, c: combined.c, d: combined.d,
                                       tx: 0, ty: 0)
        let vertical = CGPoint(x: 0, y: 1).applying(linear)
        let horizontal = CGPoint(x: 1, y: 0).applying(linear)
        let fontSize = text.fontSize * hypot(vertical.x, vertical.y)

        // Section 9.4.4: tx = ((w0 * Tfs) + Tc + (isWordSpace ? Tw : 0)) * Th.
        let tx = (char.width * text.fontSize + text.charSpacing
            + (char.isWordSpace ? text.wordSpacing : 0)) * text.horizontalScaling
        let advance = tx * hypot(horizontal.x, horizontal.y)

        glyphs.append(PDFGlyph(unicode: char.unicode, origin: origin, advance: advance,
                               fontSize: fontSize, fontName: decoder.fontName, style: decoder.style,
                               opIndex: opIndex, renderMode: text.renderMode,
                               isUpright: Self.isUpright(horizontal: horizontal, vertical: vertical),
                               color: gstate.fillColor))
        textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
    }

    static func deviceColor(_ components: [CGFloat]) -> PDFColor? {
        let c = components.map { min(max($0, 0), 1) }
        switch c.count {
        case 1: return PDFColor(red: c[0], green: c[0], blue: c[0])
        case 3: return PDFColor(red: c[0], green: c[1], blue: c[2])
        case 4: return PDFColor(red: (1 - c[0]) * (1 - c[3]), green: (1 - c[1]) * (1 - c[3]),
                                blue: (1 - c[2]) * (1 - c[3]))
        default: return nil
        }
    }

    /// The text space x axis maps to page +x and the y axis to page +y, within a small tolerance.
    static func isUpright(horizontal: CGPoint, vertical: CGPoint) -> Bool {
        horizontal.x > 0 && abs(horizontal.y) <= horizontal.x * 0.05
            && vertical.y > 0 && abs(vertical.x) <= vertical.y * 0.05
    }

    // MARK: - Graphics

    private mutating func addXObject(_ kind: PDFGraphic.Kind) {
        let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)
        graphics.append(PDFGraphic(kind: kind, bounds: unitSquare.applying(gstate.ctm), stream: stream))
    }

    /// Draws a form XObject the way `Do` does: the form's /Matrix is concatenated
    /// to the CTM, its content is read with its own resources, and the graphics
    /// state is restored afterwards.
    private mutating func drawForm(_ source: PDFFormSource) {
        // A form that draws itself, directly or through another form, would
        // never finish. Eight levels is far beyond any real document.
        guard formStack.count < 8, !formStack.contains(source.index) else { return }

        let savedState = gstate
        let parentStates = savedStates
        // The sentinel absorbs a stray Q in the form's own content.
        savedStates.append(gstate)
        let savedFonts = fonts
        let savedKinds = xobjectKinds
        let savedResolver = resolver
        let savedStream = stream

        formStack.append(source.index)
        gstate.ctm = source.matrix.concatenating(gstate.ctm)
        // A form with no resources of its own is damaged, but its text still
        // reads when the resources of the stream that drew it are used.
        if !source.fonts.isEmpty { fonts = source.fonts }
        if !source.xobjectKinds.isEmpty { xobjectKinds = source.xobjectKinds }
        if let nested = source.resolver { resolver = nested }
        stream = source.index
        run(source.content)

        stream = savedStream
        resolver = savedResolver
        xobjectKinds = savedKinds
        fonts = savedFonts
        formStack.removeLast()
        // A form may leave q/Q unbalanced; the drawing stream must not inherit that.
        savedStates = parentStates
        gstate = savedState
    }

    private mutating func paintPath(byteRange: Range<Int>) {
        defer { pathPoints.removeAll(keepingCapacity: true) }
        guard !pathPoints.isEmpty else { return }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in pathPoints {
            let transformed = point.applying(gstate.ctm)
            minX = min(minX, transformed.x)
            maxX = max(maxX, transformed.x)
            minY = min(minY, transformed.y)
            maxY = max(maxY, transformed.y)
        }
        // A path with no extent paints nothing.
        guard maxX > minX || maxY > minY else { return }
        graphics.append(PDFGraphic(kind: .path,
                                   bounds: CGRect(x: minX, y: minY,
                                                  width: maxX - minX, height: maxY - minY),
                                   byteRange: byteRange, stream: stream))
    }
}
