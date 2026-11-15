import CoreGraphics
import Foundation

/// Everything the decoder needs to know about one font resource. It is plain
/// data so that a font can be read once and decoded without CoreGraphics.
public struct PDFFontDescription: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case type1, trueType, type3, type0
    }

    /// FontMatrix of a normal font: glyph space is 1/1000 of text space.
    public static let unitFontMatrix = CGAffineTransform(scaleX: 0.001, y: 0.001)

    public var kind: Kind
    /// Raw BaseFont, including a possible "ABCDEF+" subset prefix.
    public var baseFont: String
    public var firstChar: Int
    /// Simple fonts, in glyph space (1/1000 em, or the Type 3 glyph space).
    public var widths: [CGFloat]
    /// FontDescriptor MissingWidth.
    public var missingWidth: CGFloat
    /// Type 3 only; the 1/1000 scale for every other font.
    public var fontMatrix: CGAffineTransform
    public var baseEncoding: String?
    /// Encoding /Differences: code to glyph name.
    public var differences: [Int: String]
    /// Decoded ToUnicode CMap stream.
    public var toUnicode: [UInt8]?
    /// Type 0 Encoding name, for example "Identity-H".
    public var cidEncoding: String?
    /// DW, default 1000.
    public var defaultCIDWidth: CGFloat
    /// Widths from the W array.
    public var cidWidths: [Int: CGFloat]
    /// FontDescriptor /Flags.
    public var descriptorFlags: Int
    /// The built-in encoding of an embedded Type 1 program (code to glyph name),
    /// which applies when the font dictionary names no base encoding.
    public var builtinEncoding: [Int: String] = [:]
    /// Symbol or ZapfDingbats without a font program: its built-in encoding is
    /// not one of the three predefined encodings, so codes stay unmapped.
    public var isSymbolicStandard14: Bool

    public init(
        kind: Kind = .type1,
        baseFont: String = "",
        firstChar: Int = 0,
        widths: [CGFloat] = [],
        missingWidth: CGFloat = 0,
        fontMatrix: CGAffineTransform = PDFFontDescription.unitFontMatrix,
        baseEncoding: String? = nil,
        differences: [Int: String] = [:],
        toUnicode: [UInt8]? = nil,
        cidEncoding: String? = nil,
        defaultCIDWidth: CGFloat = 1000,
        cidWidths: [Int: CGFloat] = [:],
        descriptorFlags: Int = 0,
        isSymbolicStandard14: Bool = false
    ) {
        self.kind = kind
        self.baseFont = baseFont
        self.firstChar = firstChar
        self.widths = widths
        self.missingWidth = missingWidth
        self.fontMatrix = fontMatrix
        self.baseEncoding = baseEncoding
        self.differences = differences
        self.toUnicode = toUnicode
        self.cidEncoding = cidEncoding
        self.defaultCIDWidth = defaultCIDWidth
        self.cidWidths = cidWidths
        self.descriptorFlags = descriptorFlags
        self.isSymbolicStandard14 = isSymbolicStandard14
    }
}

/// Turns the string operands of text-showing operators into characters for one
/// font resource: code splitting, Unicode and glyph widths.
public struct PDFFontDecoder: PDFCharDecoding {
    public let description: PDFFontDescription
    public let fontName: String
    public let style: PDFFontStyle

    private let cmap: PDFToUnicodeCMap?
    /// Glyph names of the base encoding, indexed by code. Empty for Type 0 fonts.
    private let encodingNames: [String]
    private let standard14: Standard14?

    public init(_ description: PDFFontDescription) {
        self.description = description
        fontName = PDFFontDecoder.strippingSubsetPrefix(description.baseFont)
        style = PDFFontDecoder.style(forBaseFont: description.baseFont, flags: description.descriptorFlags)
        cmap = description.toUnicode.map { PDFToUnicodeCMap($0) }
        encodingNames = PDFFontDecoder.encodingNames(for: description)
        standard14 = description.kind == .type0 ? nil : PDFFontDecoder.standard14Font(named: fontName)
    }

    public func decode(_ bytes: [UInt8]) -> [PDFDecodedChar] {
        var characters: [PDFDecodedChar] = []
        var index = 0
        while index < bytes.count {
            let length = min(codeLength(in: bytes, at: index), bytes.count - index)
            var code = 0
            for offset in 0..<length { code = code << 8 | Int(bytes[index + offset]) }
            let unicode = unicode(for: code)
            characters.append(PDFDecodedChar(code: code, unicode: unicode,
                                             width: width(for: code, unicode: unicode),
                                             isWordSpace: length == 1 && code == 32))
            index += length
        }
        return characters
    }

    // MARK: - BaseFont name

    /// The BaseFont without a six uppercase letter subset prefix and its "+".
    public static func strippingSubsetPrefix(_ name: String) -> String {
        let characters = Array(name)
        guard characters.count > 7, characters[6] == "+",
              characters[0..<6].allSatisfy({ $0.isASCII && $0.isUppercase && $0.isLetter }) else {
            return name
        }
        return String(characters[7...])
    }

    // MARK: - Code splitting

    private func codeLength(in bytes: [UInt8], at index: Int) -> Int {
        if let cmap, let length = cmap.codeLength(in: bytes, at: index) { return length }
        // Without a codespace range: one byte for simple fonts, two for Type 0.
        // Predefined CMaps other than Identity-H/V are not shipped, so their
        // codes are read as two bytes as an approximation.
        return description.kind == .type0 ? 2 : 1
    }

    // MARK: - Unicode

    private func unicode(for code: Int) -> String {
        if let cmap, let text = cmap.unicode(for: code) { return text }
        guard description.kind != .type0 else { return "" }
        let baseName = code >= 0 && code < encodingNames.count ? encodingNames[code] : ""
        if let text = PDFGlyphNames.unicode(for: description.differences[code] ?? baseName) { return text }
        // A Differences name we do not know still leaves the base encoding.
        if description.differences[code] != nil, let text = PDFGlyphNames.unicode(for: baseName) {
            return text
        }
        return ""
    }

    /// Glyph names of the encoding that applies before /Differences.
    private static func encodingNames(for description: PDFFontDescription) -> [String] {
        guard description.kind != .type0 else { return [] }
        if let name = description.baseEncoding {
            // An encoding we do not ship (MacExpertEncoding, for example) must not
            // fall back to a different table, which would decode to wrong letters.
            return PDFGlyphNames.encoding(named: name) ?? [String](repeating: "", count: 256)
        }
        // A Symbol or ZapfDingbats font without a program uses its own built-in
        // encoding, which is not one of the three predefined tables.
        if description.isSymbolicStandard14 { return [String](repeating: "", count: 256) }
        // An embedded Type 1 program carries its own encoding. TeX math fonts rely
        // on it: code 0x50 of cmex is the summation sign, not "P".
        if !description.builtinEncoding.isEmpty {
            var names = [String](repeating: "", count: 256)
            for (code, name) in description.builtinEncoding where code >= 0 && code < 256 {
                names[code] = name
            }
            return names
        }
        // Adobe's Type 1 fonts without /Encoding use StandardEncoding. Quartz and
        // most Windows producers write TrueType fonts in the WinAnsi code page.
        let fallback = description.kind == .trueType ? "WinAnsiEncoding" : "StandardEncoding"
        return PDFGlyphNames.encoding(named: fallback) ?? [String](repeating: "", count: 256)
    }

    // MARK: - Widths

    private func width(for code: Int, unicode: String) -> CGFloat {
        let glyphSpace: CGFloat
        switch description.kind {
        case .type0:
            // For Identity encodings the CID is the code. Other predefined CMaps
            // are approximated the same way rather than shipping their tables.
            glyphSpace = description.cidWidths[code] ?? description.defaultCIDWidth
        default:
            let offset = code - description.firstChar
            if offset >= 0, offset < description.widths.count {
                glyphSpace = description.widths[offset]
            } else if description.widths.isEmpty, let standard14 {
                glyphSpace = standard14.width(for: unicode)
            } else {
                glyphSpace = description.missingWidth
            }
        }
        return glyphSpace * description.fontMatrix.a
    }

    /// The standard 14 fonts are the only fonts a viewer must know without a
    /// /Widths array. Shipping their metric tables would mean shipping Adobe
    /// data, so the widths below are averages per character class.
    private enum Standard14 {
        case courier, times, helvetica, symbol

        func width(for unicode: String) -> CGFloat {
            switch self {
            case .courier, .symbol:
                return 600
            case .times:
                return Self.averageWidth(for: unicode, space: 250, digit: 500, upper: 667,
                                         lower: 500, punctuation: 333, other: 500)
            case .helvetica:
                return Self.averageWidth(for: unicode, space: 278, digit: 556, upper: 667,
                                         lower: 556, punctuation: 333, other: 556)
            }
        }

        private static func averageWidth(
            for unicode: String, space: CGFloat, digit: CGFloat, upper: CGFloat,
            lower: CGFloat, punctuation: CGFloat, other: CGFloat
        ) -> CGFloat {
            guard let scalar = unicode.unicodeScalars.first else { return other }
            switch scalar.value {
            case 0x20: return space
            case 0x30...0x39: return digit
            case 0x41...0x5A: return upper
            case 0x61...0x7A: return lower
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return punctuation
            default: return other
            }
        }
    }

    private static func standard14Font(named name: String) -> Standard14? {
        let name = name.lowercased()
        if name.hasPrefix("courier") { return .courier }
        if name.hasPrefix("times") { return .times }
        if name.hasPrefix("helvetica") || name.hasPrefix("arial") { return .helvetica }
        if name.hasPrefix("symbol") || name.hasPrefix("zapfdingbats") { return .symbol }
        return nil
    }

    // MARK: - Style

    /// Style facts from the font name and the FontDescriptor flags.
    public static func style(forBaseFont baseFont: String, flags: Int) -> PDFFontStyle {
        let name = strippingSubsetPrefix(baseFont).lowercased()
        let monospace = flags & 1 != 0 || contains(name, ["courier", "mono", "typewriter", "cmtt", "consolas", "menlo"])
        let serifName = contains(name, ["times", "roman", "serif", "mincho", "hiramin", "nimbusrom",
                                       "cmr", "minion", "garamond", "georgia", "cambria", "palatino",
                                       "book", "ming", "song"])
        let sansName = contains(name, ["helvetica", "arial", "sans", "gothic", "calibri", "verdana",
                                      "hirakaku", "kaku"])
        let bold = contains(name, ["bold", "black", "heavy", "semibold", "demi", "medi"])
            || name.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains("b")
            || contains(name, ["w6", "w7", "w8", "w9"])
            || flags & (1 << 18) != 0
        let italic = flags & 64 != 0
            || contains(name, ["italic", "oblique", "slanted", "cmmi", "cmti"])
            || name.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains("it")
        let math = mathPrefixes.contains { name.hasPrefix($0) } || name.contains("math")
        return PDFFontStyle(isSerif: !sansName && (serifName || flags & 2 != 0),
                            isBold: bold, isItalic: italic, isMath: math, isMonospace: monospace)
    }

    private static let mathPrefixes = [
        "cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msam", "msbm", "eufm", "eusm", "rsfs",
        "stixmath", "stixtwomath", "cambriamath", "latinmodernmath", "xitsmath", "symbol",
        "mtsy", "mtex", "rmtmi",
    ]

    private static func contains(_ name: String, _ needles: [String]) -> Bool {
        needles.contains { name.contains($0) }
    }
}
