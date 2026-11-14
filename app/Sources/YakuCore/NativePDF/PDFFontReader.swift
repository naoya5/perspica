import CoreGraphics
import Foundation

/// Reads font dictionaries through CoreGraphics into plain descriptions.
public enum PDFFontReader {
    /// Every entry of a page's /Resources /Font dictionary, keyed by resource name.
    public static func fonts(in resources: CGPDFDictionaryRef) -> [String: PDFFontDescription] {
        guard let fonts = dictionary(resources, "Font") else { return [:] }
        var descriptions: [String: PDFFontDescription] = [:]
        CGPDFDictionaryApplyBlock(fonts, { key, value, _ in
            var font: CGPDFDictionaryRef? = nil
            if CGPDFObjectGetValue(value, .dictionary, &font), let font {
                descriptions[String(cString: key)] = description(of: font)
            }
            return true
        }, nil)
        return descriptions
    }

    public static func description(of font: CGPDFDictionaryRef) -> PDFFontDescription {
        var result = PDFFontDescription(kind: kind(of: name(font, "Subtype")))
        result.baseFont = name(font, "BaseFont") ?? ""

        var descriptor: CGPDFDictionaryRef?
        if result.kind == .type0 {
            result.cidEncoding = name(font, "Encoding")
            descriptor = readDescendantFont(of: font, into: &result)
        } else {
            result.firstChar = integer(font, "FirstChar") ?? 0
            if let widths = array(font, "Widths") { result.widths = numbers(widths) }
            readEncoding(of: font, into: &result)
            descriptor = dictionary(font, "FontDescriptor")
            if result.kind == .type3, let matrix = array(font, "FontMatrix") {
                let values = numbers(matrix)
                if values.count == 6 {
                    result.fontMatrix = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                                          d: values[3], tx: values[4], ty: values[5])
                }
            }
        }

        if let descriptor {
            result.descriptorFlags = integer(descriptor, "Flags") ?? 0
            result.missingWidth = number(descriptor, "MissingWidth") ?? 0
            let hasProgram = stream(descriptor, "FontFile") != nil
                || stream(descriptor, "FontFile2") != nil
                || stream(descriptor, "FontFile3") != nil
            result.isSymbolicStandard14 = !hasProgram && isSymbolicStandard14(result.baseFont)
        }
        if let toUnicode = stream(font, "ToUnicode") {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(toUnicode, &format) {
                result.toUnicode = [UInt8](data as Data)
            }
        }
        return result
    }

    // MARK: - Pieces

    private static func kind(of subtype: String?) -> PDFFontDescription.Kind {
        switch subtype {
        case "Type0": return .type0
        case "TrueType": return .trueType
        case "Type3": return .type3
        default: return .type1
        }
    }

    /// Reads DW and W from the first descendant font, which is also where a
    /// CID font keeps its FontDescriptor.
    private static func readDescendantFont(
        of font: CGPDFDictionaryRef, into result: inout PDFFontDescription
    ) -> CGPDFDictionaryRef? {
        guard let descendants = array(font, "DescendantFonts"), CGPDFArrayGetCount(descendants) > 0,
              let descendant = dictionary(descendants, at: 0) else { return nil }
        result.defaultCIDWidth = number(descendant, "DW") ?? 1000
        if let widths = array(descendant, "W") { result.cidWidths = cidWidths(from: widths) }
        return dictionary(descendant, "FontDescriptor")
    }

    /// A W array holds `c [w1 w2 ...]` and `c_first c_last w` runs, in any mix.
    private static func cidWidths(from runs: CGPDFArrayRef) -> [Int: CGFloat] {
        var widths: [Int: CGFloat] = [:]
        let count = CGPDFArrayGetCount(runs)
        var index = 0
        while index < count {
            guard let first = integer(runs, at: index) else {
                index += 1
                continue
            }
            index += 1
            guard index < count else { break }
            if let list = array(runs, at: index) {
                for (offset, width) in numbers(list).enumerated() {
                    widths[first + offset] = width
                }
                index += 1
            } else if index + 1 < count, let last = integer(runs, at: index),
                      let width = number(runs, at: index + 1) {
                if last >= first {
                    for cid in first...last { widths[cid] = width }
                }
                index += 2
            } else {
                index += 1
            }
        }
        return widths
    }

    private static func readEncoding(of font: CGPDFDictionaryRef, into result: inout PDFFontDescription) {
        if let name = name(font, "Encoding") {
            result.baseEncoding = name
            return
        }
        guard let encoding = dictionary(font, "Encoding") else { return }
        result.baseEncoding = name(encoding, "BaseEncoding")
        guard let differences = array(encoding, "Differences") else { return }
        var code = 0
        for index in 0..<CGPDFArrayGetCount(differences) {
            if let value = integer(differences, at: index) {
                code = value
            } else if let glyph = name(differences, at: index) {
                result.differences[code] = glyph
                code += 1
            }
        }
    }

    private static func isSymbolicStandard14(_ baseFont: String) -> Bool {
        let name = PDFFontDecoder.strippingSubsetPrefix(baseFont)
        let family = name.split(separator: ",").first.map(String.init) ?? name
        return family == "Symbol" || family == "ZapfDingbats"
    }

    // MARK: - CoreGraphics accessors

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, key, &value) else { return nil }
        return Int(value)
    }

    private static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dictionary, key, &value) else { return nil }
        return CGFloat(value)
    }

    private static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef? = nil
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    private static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(dictionary, key, &value) else { return nil }
        return value
    }

    private static func stream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef? = nil
        guard CGPDFDictionaryGetStream(dictionary, key, &value) else { return nil }
        return value
    }

    private static func dictionary(_ array: CGPDFArrayRef, at index: Int) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef? = nil
        guard CGPDFArrayGetDictionary(array, index, &value) else { return nil }
        return value
    }

    private static func array(_ array: CGPDFArrayRef, at index: Int) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef? = nil
        guard CGPDFArrayGetArray(array, index, &value) else { return nil }
        return value
    }

    private static func integer(_ array: CGPDFArrayRef, at index: Int) -> Int? {
        var value: CGPDFInteger = 0
        if CGPDFArrayGetInteger(array, index, &value) { return Int(value) }
        var real: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &real) else { return nil }
        return Int(real)
    }

    private static func number(_ array: CGPDFArrayRef, at index: Int) -> CGFloat? {
        var value: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
        return CGFloat(value)
    }

    private static func name(_ array: CGPDFArrayRef, at index: Int) -> String? {
        var pointer: UnsafePointer<CChar>? = nil
        guard CGPDFArrayGetName(array, index, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func numbers(_ array: CGPDFArrayRef) -> [CGFloat] {
        (0..<CGPDFArrayGetCount(array)).map { number(array, at: $0) ?? 0 }
    }
}
