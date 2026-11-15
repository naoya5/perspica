import CoreGraphics
import Foundation

// Shared types of the native PDF translator. Every module of NativePDF codes
// against these. Coordinates are PDF default user space of the page: origin at
// the bottom-left corner of the media box, y grows upward, 1 unit = 1 point.

/// One character decoded from a string operand of a text-showing operator.
public struct PDFDecodedChar: Sendable, Equatable {
    /// The character code read from the string (1 byte for simple fonts, 2 bytes for Identity CID fonts).
    public var code: Int
    /// Unicode text for this code. Empty when the font gives no mapping.
    public var unicode: String
    /// Horizontal displacement in text space units before Tc/Tw/Tz/size
    /// are applied: glyph width / 1000 for normal fonts (FontMatrix-scaled for Type 3).
    public var width: CGFloat
    /// True only for single-byte code 32, the one code that word spacing (Tw) applies to.
    public var isWordSpace: Bool

    public init(code: Int, unicode: String, width: CGFloat, isWordSpace: Bool) {
        self.code = code
        self.unicode = unicode
        self.width = width
        self.isWordSpace = isWordSpace
    }
}

/// Style facts about a font, read from its name and font descriptor.
public struct PDFFontStyle: Sendable, Equatable {
    public var isSerif: Bool
    public var isBold: Bool
    public var isItalic: Bool
    /// The font is a math font (Computer Modern math, AMS symbols, STIX math, Symbol and similar).
    public var isMath: Bool
    /// The font is monospaced (fixed pitch flag or a typewriter/mono name).
    public var isMonospace: Bool

    public init(isSerif: Bool, isBold: Bool, isItalic: Bool, isMath: Bool, isMonospace: Bool) {
        self.isSerif = isSerif
        self.isBold = isBold
        self.isItalic = isItalic
        self.isMath = isMath
        self.isMonospace = isMonospace
    }
}

/// A fill color in device RGB, each component 0...1.
public struct PDFColor: Sendable, Equatable, Hashable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = PDFColor(red: 0, green: 0, blue: 0)

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// Turns string operand bytes into characters for one font resource.
public protocol PDFCharDecoding: Sendable {
    /// BaseFont without the six-letter subset prefix ("ABCDEF+").
    var fontName: String { get }
    var style: PDFFontStyle { get }
    func decode(_ bytes: [UInt8]) -> [PDFDecodedChar]
}

/// One glyph placed on the page by a text-showing operator.
public struct PDFGlyph: Sendable, Equatable {
    public var unicode: String
    /// Baseline start of the glyph in page space.
    public var origin: CGPoint
    /// Displacement along the baseline in page space (includes Tc, Tw and Tz).
    public var advance: CGFloat
    /// Effective font size in page space (Tf size scaled by the text matrix and CTM).
    public var fontSize: CGFloat
    public var fontName: String
    public var style: PDFFontStyle
    /// Index into `PDFPageContent.showOps` of the operator that drew this glyph.
    public var opIndex: Int
    /// Text render mode (Tr) in effect. 3 and 7 draw nothing visible.
    public var renderMode: Int
    /// The baseline runs left to right along the page's x axis. Rotated or
    /// mirrored text (such as an arXiv identifier along the margin) is false.
    public var isUpright: Bool
    /// The nonstroking color in effect, which is what fills glyphs in the usual render mode 0.
    public var color: PDFColor

    public init(unicode: String, origin: CGPoint, advance: CGFloat, fontSize: CGFloat, fontName: String,
                style: PDFFontStyle, opIndex: Int, renderMode: Int, isUpright: Bool = true,
                color: PDFColor = .black) {
        self.unicode = unicode
        self.origin = origin
        self.advance = advance
        self.fontSize = fontSize
        self.fontName = fontName
        self.style = style
        self.opIndex = opIndex
        self.renderMode = renderMode
        self.isUpright = isUpright
        self.color = color
    }

    /// Approximate glyph box: from the baseline down 0.22 em, up 0.78 em.
    public var bounds: CGRect {
        CGRect(x: min(origin.x, origin.x + advance), y: origin.y - fontSize * 0.22,
               width: abs(advance), height: fontSize)
    }
}

/// One text-showing operator (Tj, TJ, ' or ") in a content stream of the page.
public struct PDFShowOp: Sendable, Equatable {
    /// Bytes of the operator and its operands in its content stream.
    public var byteRange: Range<Int>
    /// The operator: "Tj", "TJ", "'" or "\"".
    public var op: String
    /// Indices into `PDFPageContent.glyphs` drawn by this operator.
    public var glyphRange: Range<Int>
    /// Index into `PDFPageContent.streams` of the content stream holding the
    /// operator. 0 is the page's own content, 1 and up are form XObjects.
    public var stream: Int

    public init(byteRange: Range<Int>, op: String, glyphRange: Range<Int>, stream: Int = 0) {
        self.byteRange = byteRange
        self.op = op
        self.glyphRange = glyphRange
        self.stream = stream
    }
}

/// What a painting operator put on the page, for finding figures.
public struct PDFGraphic: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An image XObject or an inline image.
        case image
        /// A form XObject drawn with Do (its own content is not interpreted).
        case form
        /// A filled and/or stroked path.
        case path
    }

    public var kind: Kind
    /// Bounding box in page space.
    public var bounds: CGRect
    /// For paths: the bytes from the first path construction operator to the
    /// painting operator, so a path (such as a fraction bar inside a moved
    /// inline formula) can be removed. Nil for images and forms.
    public var byteRange: Range<Int>?
    /// Index into `PDFPageContent.streams` of the content stream that painted
    /// the graphic. 0 is the page's own content, 1 and up are form XObjects.
    public var stream: Int

    public init(kind: Kind, bounds: CGRect, byteRange: Range<Int>? = nil, stream: Int = 0) {
        self.kind = kind
        self.bounds = bounds
        self.byteRange = byteRange
        self.stream = stream
    }
}

/// The interpreted content of one page.
public struct PDFPageContent: Sendable, Equatable {
    public var glyphs: [PDFGlyph]
    public var showOps: [PDFShowOp]
    public var graphics: [PDFGraphic]
    /// Decoded content streams of the page, indexed by the `stream` of the
    /// operators and graphics. Index 0 is the page's own content; each form
    /// XObject the page draws gets one entry.
    public var streams: [[UInt8]]

    public init(glyphs: [PDFGlyph], showOps: [PDFShowOp], graphics: [PDFGraphic],
                streams: [[UInt8]] = []) {
        self.glyphs = glyphs
        self.showOps = showOps
        self.graphics = graphics
        self.streams = streams
    }
}

/// A piece of a paragraph's text.
public enum PDFTextSegment: Sendable, Equatable {
    /// Ordinary text to translate.
    case text(String)
    /// An inline formula. It is not translated: the typesetter places the
    /// original glyphs (copied from `bounds` on the source page) inline.
    /// `text` is its Unicode form, used only when the formula cannot be placed.
    case formula(text: String, bounds: CGRect, baseline: CGFloat)
}

/// A block of text found on a page.
public struct PDFParagraph: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case body, heading, caption, listItem, footnote
        /// Page number, running header or footer.
        case pageFurniture
        /// A display formula line or block.
        case formula
        /// Text inside a figure, or code, numbers, tables and similar.
        case other
    }

    public var role: Role
    /// Union of the line boxes.
    public var bounds: CGRect
    /// One box per original line, top to bottom.
    public var lineBounds: [CGRect]
    public var segments: [PDFTextSegment]
    /// Glyph indices (into `PDFPageContent.glyphs`) that belong to this paragraph,
    /// formula glyphs included.
    public var glyphIndices: [Int]
    /// Dominant font size in page space.
    public var fontSize: CGFloat
    public var style: PDFFontStyle
    /// True when the translator should translate this block and replace it.
    public var translate: Bool

    public init(role: Role, bounds: CGRect, lineBounds: [CGRect], segments: [PDFTextSegment],
                glyphIndices: [Int], fontSize: CGFloat, style: PDFFontStyle, translate: Bool) {
        self.role = role
        self.bounds = bounds
        self.lineBounds = lineBounds
        self.segments = segments
        self.glyphIndices = glyphIndices
        self.fontSize = fontSize
        self.style = style
        self.translate = translate
    }
}
