import Foundation

/// A value that can appear as an operand in a content stream.
public indirect enum PDFContentValue: Sendable, Equatable {
    case number(Double)
    case name(String)
    case string([UInt8])
    case boolean(Bool)
    case null
    case array([PDFContentValue])
    case dictionary([String: PDFContentValue])
}

/// One token of a decoded page content stream.
public struct PDFContentToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case number(Double)
        case name(String)
        /// A literal or hex string. PDF treats both as byte strings, so the
        /// lexer does not keep the syntax apart.
        case string([UInt8])
        case boolean(Bool)
        case null
        case arrayStart
        case arrayEnd
        case dictionaryStart
        case dictionaryEnd
        case op(String)
        /// A whole `BI ... EI` inline image. The entries are the ones between
        /// `BI` and `ID`; the binary data itself is skipped.
        case inlineImage([String: PDFContentValue])
    }

    public var kind: Kind
    /// Offset of the first byte of the token in the content stream.
    public var start: Int
    /// Offset one past the last byte of the token.
    public var end: Int

    public init(kind: Kind, start: Int, end: Int) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// Splits a decoded page content stream into tokens with byte offsets.
///
/// The lexer is deliberately permissive: a malformed stream must never trap,
/// because a damaged page should still be translated as far as possible.
public struct PDFContentLexer: Sendable {
    private let bytes: [UInt8]
    private var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    /// Returns the next token, or nil at the end of the stream.
    public mutating func next() -> PDFContentToken? {
        guard let token = readToken() else { return nil }
        // An inline image is one syntactic unit from BI to EI, so the caller
        // never sees the dictionary entries as loose operands.
        if case .op("BI") = token.kind {
            return readInlineImage(start: token.start)
        }
        return token
    }

    // MARK: - Token scanning

    private mutating func readToken() -> PDFContentToken? {
        while true {
            skipWhitespaceAndComments()
            guard offset < bytes.count else { return nil }
            let start = offset
            switch bytes[offset] {
            case 0x5B: // [
                offset += 1
                return PDFContentToken(kind: .arrayStart, start: start, end: offset)
            case 0x5D: // ]
                offset += 1
                return PDFContentToken(kind: .arrayEnd, start: start, end: offset)
            case 0x3C: // <
                if peek(1) == 0x3C {
                    offset += 2
                    return PDFContentToken(kind: .dictionaryStart, start: start, end: offset)
                }
                return PDFContentToken(kind: .string(readHexString()), start: start, end: offset)
            case 0x3E: // >
                if peek(1) == 0x3E {
                    offset += 2
                    return PDFContentToken(kind: .dictionaryEnd, start: start, end: offset)
                }
                // A lone '>' is not valid PDF. Skip it rather than derailing
                // the rest of the stream.
                offset += 1
            case 0x28: // (
                return PDFContentToken(kind: .string(readLiteralString()), start: start, end: offset)
            case 0x2F: // /
                offset += 1
                return PDFContentToken(kind: .name(readName()), start: start, end: offset)
            case 0x7B, 0x7D: // { }
                // PostScript procedure braces have no meaning in a PDF content
                // stream. Ignore them so a stray pair cannot hide the next token.
                offset += 1
            default:
                guard let word = readWord() else {
                    offset += 1
                    continue
                }
                return PDFContentToken(kind: classify(word), start: start, end: offset)
            }
        }
    }

    private mutating func readWord() -> [UInt8]? {
        let start = offset
        while offset < bytes.count,
              !Self.isWhitespace(bytes[offset]),
              !Self.isDelimiter(bytes[offset]) {
            offset += 1
        }
        guard offset > start else { return nil }
        return Array(bytes[start..<offset])
    }

    private func classify(_ word: [UInt8]) -> PDFContentToken.Kind {
        if let number = Self.number(from: word) {
            return .number(number)
        }
        switch String(decoding: word, as: UTF8.self) {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "null": return .null
        default: return .op(String(decoding: word, as: UTF8.self))
        }
    }

    // MARK: - Names

    private mutating func readName() -> String {
        var out: [UInt8] = []
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == 0x23, let high = peek(1).flatMap(Self.hexValue),
               let low = peek(2).flatMap(Self.hexValue) {
                out.append(high << 4 | low)
                offset += 3
            } else if Self.isWhitespace(byte) || Self.isDelimiter(byte) {
                break
            } else {
                out.append(byte)
                offset += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Strings

    private mutating func readLiteralString() -> [UInt8] {
        offset += 1 // (
        var out: [UInt8] = []
        var depth = 1
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 0x5C { // backslash
                guard offset < bytes.count else { return out }
                let escaped = bytes[offset]
                offset += 1
                switch escaped {
                case 0x6E: out.append(0x0A) // \n
                case 0x72: out.append(0x0D) // \r
                case 0x74: out.append(0x09) // \t
                case 0x62: out.append(0x08) // \b
                case 0x66: out.append(0x0C) // \f
                case 0x28, 0x29, 0x5C: out.append(escaped) // \( \) \\
                case 0x0D:
                    // A backslash before an end-of-line is a continuation.
                    if offset < bytes.count, bytes[offset] == 0x0A { offset += 1 }
                case 0x0A:
                    break
                case 0x30...0x37:
                    var value = Int(escaped - 0x30)
                    var digits = 1
                    while digits < 3, offset < bytes.count, (0x30...0x37).contains(bytes[offset]) {
                        value = value * 8 + Int(bytes[offset] - 0x30)
                        offset += 1
                        digits += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: value))
                default:
                    // An unknown escape stands for the character itself.
                    out.append(escaped)
                }
            } else if byte == 0x28 { // (
                depth += 1
                out.append(byte)
            } else if byte == 0x29 { // )
                depth -= 1
                if depth == 0 { return out }
                out.append(byte)
            } else {
                out.append(byte)
            }
        }
        return out
    }

    private mutating func readHexString() -> [UInt8] {
        offset += 1 // <
        var out: [UInt8] = []
        var high: UInt8?
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 0x3E { break }
            guard let value = Self.hexValue(byte) else { continue }
            if let pending = high {
                out.append(pending << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        // An odd number of digits is padded with a trailing zero nibble.
        if let pending = high { out.append(pending << 4) }
        return out
    }

    // MARK: - Inline images

    private mutating func readInlineImage(start: Int) -> PDFContentToken {
        var entries: [String: PDFContentValue] = [:]
        while true {
            skipWhitespaceAndComments()
            guard offset < bytes.count else {
                return PDFContentToken(kind: .inlineImage(entries), start: start, end: offset)
            }
            if isInlineImageDataStart() {
                offset += 2 // ID
                skipInlineImageData()
                return PDFContentToken(kind: .inlineImage(entries), start: start, end: offset)
            }
            guard let token = readToken() else {
                offset += 1
                continue
            }
            if case .name(let key) = token.kind, let value = readValue() {
                entries[key] = value
            }
        }
    }

    private func isInlineImageDataStart() -> Bool {
        bytes[offset] == 0x49 // I
            && peek(1) == 0x44 // D
            && (offset + 2 >= bytes.count || Self.isWhitespace(bytes[offset + 2]))
    }

    private mutating func skipInlineImageData() {
        var index = offset
        while index + 1 < bytes.count {
            // EI only ends the data when whitespace precedes it and whitespace
            // or the end of the stream follows it. Image bytes can contain the
            // letters EI anywhere else.
            if bytes[index] == 0x45, bytes[index + 1] == 0x49,
               index > offset, Self.isWhitespace(bytes[index - 1]),
               index + 2 >= bytes.count || Self.isWhitespace(bytes[index + 2]) {
                offset = index + 2
                return
            }
            index += 1
        }
        offset = bytes.count
    }

    // MARK: - Values

    private mutating func readValue() -> PDFContentValue? {
        guard let token = readToken() else { return nil }
        return value(from: token)
    }

    private mutating func value(from token: PDFContentToken) -> PDFContentValue? {
        switch token.kind {
        case .number(let value): return .number(value)
        case .name(let name): return .name(name)
        case .string(let string): return .string(string)
        case .boolean(let value): return .boolean(value)
        case .null: return .null
        case .arrayStart:
            var items: [PDFContentValue] = []
            while let next = readToken() {
                if case .arrayEnd = next.kind { break }
                if let item = value(from: next) { items.append(item) }
            }
            return .array(items)
        case .dictionaryStart:
            var entries: [String: PDFContentValue] = [:]
            while let next = readToken() {
                if case .dictionaryEnd = next.kind { break }
                guard case .name(let key) = next.kind else { continue }
                guard let item = readValue() else { break }
                entries[key] = item
            }
            return .dictionary(entries)
        case .arrayEnd, .dictionaryEnd, .op, .inlineImage:
            return nil
        }
    }

    // MARK: - Character classes

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// Parses a PDF number: an optional sign, digits and at most one decimal
    /// point. Exponents are not part of the PDF grammar.
    private static func number(from word: [UInt8]) -> Double? {
        guard !word.isEmpty else { return nil }
        var index = 0
        if word[0] == 0x2B || word[0] == 0x2D { index = 1 }
        var digits = 0
        var points = 0
        while index < word.count {
            let byte = word[index]
            if byte == 0x2E {
                points += 1
                if points > 1 { return nil }
            } else if (0x30...0x39).contains(byte) {
                digits += 1
            } else {
                return nil
            }
            index += 1
        }
        guard digits > 0 else { return nil }
        return Double(String(decoding: word, as: UTF8.self))
    }

    private func peek(_ distance: Int) -> UInt8? {
        let index = offset + distance
        return index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespaceAndComments() {
        while offset < bytes.count {
            let byte = bytes[offset]
            if Self.isWhitespace(byte) {
                offset += 1
            } else if byte == 0x25 { // %
                while offset < bytes.count, bytes[offset] != 0x0A, bytes[offset] != 0x0D {
                    offset += 1
                }
            } else {
                return
            }
        }
    }
}
