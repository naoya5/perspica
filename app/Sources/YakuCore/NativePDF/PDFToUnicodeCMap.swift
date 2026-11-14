import Foundation

/// The part of a ToUnicode CMap that maps character codes to Unicode text.
///
/// Only `codespacerange`, `bfchar` and `bfrange` carry information we need;
/// everything else in the stream (including `usecmap`) is ignored.
public struct PDFToUnicodeCMap: Sendable, Equatable {
    /// One `codespacerange` entry: codes of `byteLength` bytes between `low` and `high`.
    public struct CodeSpaceRange: Sendable, Equatable {
        public var low: Int
        public var high: Int
        public var byteLength: Int

        public init(low: Int, high: Int, byteLength: Int) {
            self.low = low
            self.high = high
            self.byteLength = byteLength
        }
    }

    /// Shortest codespace ranges first, so the shortest code wins.
    public var codeSpaceRanges: [CodeSpaceRange]
    /// Code to Unicode text. A destination may hold several characters (a ligature)
    /// or a surrogate pair.
    public var mappings: [Int: String]

    public init(_ bytes: [UInt8]) {
        let tokens = PDFToUnicodeCMapTokenizer.tokenize(bytes)
        var ranges: [CodeSpaceRange] = []
        var mappings: [Int: String] = [:]
        var index = 0
        while index < tokens.count {
            guard case .operation(let operation) = tokens[index] else {
                index += 1
                continue
            }
            index += 1
            switch operation {
            case "begincodespacerange":
                while index + 1 < tokens.count,
                      case .string(let low) = tokens[index],
                      case .string(let high) = tokens[index + 1] {
                    if let range = PDFToUnicodeCMap.codeSpaceRange(low: low, high: high) {
                        ranges.append(range)
                    }
                    index += 2
                }
            case "beginbfchar":
                while index + 1 < tokens.count,
                      case .string(let source) = tokens[index],
                      case .string(let destination) = tokens[index + 1] {
                    mappings[PDFToUnicodeCMap.code(source)] = PDFToUnicodeCMap.text(destination)
                    index += 2
                }
            case "beginbfrange":
                while index + 2 < tokens.count,
                      case .string(let low) = tokens[index],
                      case .string(let high) = tokens[index + 1] {
                    let first = PDFToUnicodeCMap.code(low)
                    let last = PDFToUnicodeCMap.code(high)
                    index += 2
                    guard last >= first, last - first <= 0xFFFF else { continue }
                    if case .string(let destination) = tokens[index] {
                        index += 1
                        for (offset, code) in stride(from: first, through: last, by: 1).enumerated() {
                            mappings[code] = PDFToUnicodeCMap.text(
                                PDFToUnicodeCMap.increment(destination, by: offset))
                        }
                    } else if case .arrayOpen = tokens[index] {
                        index += 1
                        var offset = 0
                        while index < tokens.count, case .string(let destination) = tokens[index] {
                            mappings[first + offset] = PDFToUnicodeCMap.text(destination)
                            offset += 1
                            index += 1
                        }
                        if index < tokens.count, case .arrayClose = tokens[index] { index += 1 }
                    }
                }
            default:
                break
            }
        }
        codeSpaceRanges = ranges.sorted { $0.byteLength < $1.byteLength }
        self.mappings = mappings
    }

    /// Unicode text for a code, or nil when the CMap has no entry for it.
    public func unicode(for code: Int) -> String? {
        mappings[code]
    }

    /// Number of bytes of the code starting at `index`, decided by the codespace
    /// ranges. Nil when no range fits, for example when the bytes are truncated.
    public func codeLength(in bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index < bytes.count else { return nil }
        for range in codeSpaceRanges {
            let length = range.byteLength
            guard length > 0, index + length <= bytes.count else { continue }
            let value = PDFToUnicodeCMap.code(Array(bytes[index..<(index + length)]))
            if value >= range.low, value <= range.high { return length }
        }
        return nil
    }

    // MARK: - Bytes to values

    private static func code(_ bytes: [UInt8]) -> Int {
        bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    private static func codeSpaceRange(low: [UInt8], high: [UInt8]) -> CodeSpaceRange? {
        guard low.count == high.count, (1...4).contains(low.count) else { return nil }
        return CodeSpaceRange(low: code(low), high: code(high), byteLength: low.count)
    }

    /// Destinations are UTF-16BE. An odd byte count is repaired by adding a
    /// leading zero byte, which is what a one byte destination usually means.
    private static func text(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        if bytes.count % 2 == 1 { bytes.insert(0, at: 0) }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Adds `delta` to a destination read as one big-endian number, keeping its
    /// byte count. This is how a `bfrange` walks the last code unit of its target.
    private static func increment(_ bytes: [UInt8], by delta: Int) -> [UInt8] {
        var value = bytes.reduce(0) { $0 << 8 | Int($1) } + delta
        var result = [UInt8](repeating: 0, count: bytes.count)
        for index in stride(from: bytes.count - 1, through: 0, by: -1) {
            result[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return result
    }
}

/// Tokenizer for CMap streams: strings, names, numbers, arrays and operators.
enum PDFToUnicodeCMapTokenizer {
    enum Token: Equatable {
        case string([UInt8])
        case name(String)
        case number
        case arrayOpen
        case arrayClose
        case operation(String)
    }

    static func tokenize(_ bytes: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWhiteSpace(byte) {
                index += 1
            } else if byte == 0x25 {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else if byte == 0x28 {
                let (string, next) = literalString(bytes, from: index)
                tokens.append(.string(string))
                index = next
            } else if byte == 0x3C {
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                    tokens.append(.operation("<<"))
                    index += 2
                } else {
                    let (string, next) = hexadecimalString(bytes, from: index)
                    tokens.append(.string(string))
                    index = next
                }
            } else if byte == 0x3E {
                tokens.append(.operation(">>"))
                index += index + 1 < bytes.count && bytes[index + 1] == 0x3E ? 2 : 1
            } else if byte == 0x5B {
                tokens.append(.arrayOpen)
                index += 1
            } else if byte == 0x5D {
                tokens.append(.arrayClose)
                index += 1
            } else if byte == 0x2F {
                let (name, next) = name(bytes, from: index)
                tokens.append(.name(name))
                index = next
            } else {
                let start = index
                while index < bytes.count, !isWhiteSpace(bytes[index]), !isDelimiter(bytes[index]) {
                    index += 1
                }
                if index == start {
                    index += 1
                    continue
                }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                tokens.append(Double(word) == nil ? .operation(word) : .number)
            }
        }
        return tokens
    }

    private static func isWhiteSpace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    /// A literal string, with nested parentheses and backslash escapes.
    private static func literalString(_ bytes: [UInt8], from start: Int) -> ([UInt8], Int) {
        var index = start + 1
        var depth = 1
        var string: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                switch escape {
                case 0x6E: string.append(0x0A)
                case 0x72: string.append(0x0D)
                case 0x74: string.append(0x09)
                case 0x62: string.append(0x08)
                case 0x66: string.append(0x0C)
                case 0x0A, 0x0D: break
                case 0x30...0x37:
                    var value = 0
                    var digits = 0
                    while digits < 3, index < bytes.count, (0x30...0x37).contains(bytes[index]) {
                        value = value * 8 + Int(bytes[index] - 0x30)
                        index += 1
                        digits += 1
                    }
                    string.append(UInt8(truncatingIfNeeded: value))
                    continue
                default: string.append(escape)
                }
                index += 1
            } else if byte == 0x28 {
                depth += 1
                string.append(byte)
                index += 1
            } else if byte == 0x29 {
                depth -= 1
                index += 1
                if depth == 0 { break }
                string.append(byte)
            } else {
                string.append(byte)
                index += 1
            }
        }
        return (string, index)
    }

    private static func hexadecimalString(_ bytes: [UInt8], from start: Int) -> ([UInt8], Int) {
        var index = start + 1
        var digits: [UInt8] = []
        while index < bytes.count, bytes[index] != 0x3E {
            if !isWhiteSpace(bytes[index]) { digits.append(bytes[index]) }
            index += 1
        }
        if index < bytes.count { index += 1 }
        return (hexadecimalBytes(digits), index)
    }

    static func hexadecimalBytes(_ digits: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity((digits.count + 1) / 2)
        var index = 0
        while index < digits.count {
            let high = hexadecimalValue(digits[index])
            let low = index + 1 < digits.count ? hexadecimalValue(digits[index + 1]) : 0
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func hexadecimalValue(_ digit: UInt8) -> UInt8 {
        switch digit {
        case 0x30...0x39: return digit - 0x30
        case 0x41...0x46: return digit - 0x41 + 10
        case 0x61...0x66: return digit - 0x61 + 10
        default: return 0
        }
    }

    private static func name(_ bytes: [UInt8], from start: Int) -> (String, Int) {
        var index = start + 1
        var name = ""
        while index < bytes.count, !isWhiteSpace(bytes[index]), !isDelimiter(bytes[index]) {
            if bytes[index] == 0x23, index + 2 < bytes.count {
                let value = hexadecimalValue(bytes[index + 1]) << 4 | hexadecimalValue(bytes[index + 2])
                name.unicodeScalars.append(Unicode.Scalar(value))
                index += 3
            } else {
                name.unicodeScalars.append(Unicode.Scalar(bytes[index]))
                index += 1
            }
        }
        return (name, index)
    }
}
