import CoreGraphics
import Foundation

/// Errors thrown by `PDFRewriter`.
public enum PDFRewriteError: Error, Equatable, Sendable {
    /// The document is encrypted, so its objects cannot be copied as plain data.
    case encrypted
}

/// Writes a new PDF from the objects of an existing document, optionally
/// replacing the content streams of chosen pages.
///
/// CoreGraphics can read PDF objects but cannot write them, so the file is
/// serialized here: every dictionary and stream becomes an indirect object,
/// arrays stay inline, and a fresh cross-reference table, page tree and catalog
/// are written at the end.
public enum PDFRewriter {
    /// Contents of the page streams of one page, decoded and concatenated with
    /// a newline between streams.
    public static func content(of page: CGPDFPage) -> [UInt8] {
        guard let dictionary = page.dictionary else { return [] }
        var contents: CGPDFObjectRef? = nil
        guard CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents else { return [] }
        var out = Data()
        appendContent(of: contents, to: &out)
        return [UInt8](out)
    }

    /// Writes a copy of `document` with every page in order. For page indices
    /// (0-based) in `replacements`, the page's /Contents becomes one new stream
    /// holding the given bytes.
    ///
    /// `streamReplacements` replaces the content of individual streams, keyed by
    /// `unsafeBitCast(stream, to: UnsafeRawPointer.self)`. That is how a form
    /// XObject's content is rewritten: the page only draws it with `Do`, so the
    /// new text has to go into the form itself.
    public static func rewrite(_ document: CGPDFDocument, replacements: [Int: [UInt8]],
                               streamReplacements: [UnsafeRawPointer: [UInt8]] = [:]) throws -> Data {
        guard !document.isEncrypted else { throw PDFRewriteError.encrypted }

        let writer = PDFObjectWriter(streamReplacements: streamReplacements)
        // Pages first: every later reference to a page dictionary must resolve
        // to the object reserved here, never to a second copy.
        var pages: [PageEntry] = []
        let count = document.numberOfPages
        for index in 1..<(count + 1) {
            guard let page = document.page(at: index), let dictionary = page.dictionary else { continue }
            pages.append(PageEntry(page: page, dictionary: dictionary, id: writer.reservePage(dictionary)))
        }
        let pagesID = writer.reserve()
        let catalogID = writer.reserve()

        for (index, entry) in pages.enumerated() {
            writer.writePage(entry, parent: pagesID, replacement: replacements[index])
        }
        writer.writePagesTree(pages.map(\.id), id: pagesID)
        writer.writeCatalog(document.catalog, pagesID: pagesID, id: catalogID)
        let infoID = document.info.map { writer.dictionary($0) }
        return writer.output(root: catalogID, info: infoID)
    }

    private static func appendContent(of object: CGPDFObjectRef, to out: inout Data) {
        switch CGPDFObjectGetType(object) {
        case .stream:
            var stream: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { return }
            if !out.isEmpty { out.append(0x0A) }
            out.append(data as Data)
        case .array:
            var array: CGPDFArrayRef? = nil
            guard CGPDFObjectGetValue(object, .array, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var element: CGPDFObjectRef? = nil
                if CGPDFArrayGetObject(array, index, &element), let element {
                    appendContent(of: element, to: &out)
                }
            }
        default:
            return
        }
    }
}

/// One page of the source document and the object number reserved for it.
private struct PageEntry {
    let page: CGPDFPage
    let dictionary: CGPDFDictionaryRef
    let id: Int
}

/// Serializes PDF objects into a new file. Object numbers are handed out in
/// creation order and every dictionary and stream is memoized by pointer
/// identity, which also terminates cycles such as /Parent and /P.
private final class PDFObjectWriter {
    private var objects: [Int: Data] = [:]
    private var memo: [UnsafeRawPointer: Int] = [:]
    private var nextID = 1
    /// New decoded content of the streams whose bytes change, keyed like `memo`.
    private let streamReplacements: [UnsafeRawPointer: [UInt8]]

    init(streamReplacements: [UnsafeRawPointer: [UInt8]] = [:]) {
        self.streamReplacements = streamReplacements
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)
    /// Reals must use a dot, whatever the user's locale is.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let nameDelimiters: Set<UInt8> = Set("()<>[]{}/%#".utf8)
    /// Page keys that are written by the page writer itself or dropped because
    /// they would no longer match the new page tree and content.
    private static let handledPageKeys: Set<String> = [
        "Type", "Parent", "Contents", "Resources", "MediaBox", "CropBox", "Rotate",
        "StructParents", "PieceInfo", "Thumb", "B",
    ]
    /// Stream keys that describe the old encoding, not the decoded bytes.
    private static let handledStreamKeys: Set<String> = [
        "Length", "Filter", "DecodeParms", "DL", "JBIG2Globals",
    ]
    /// Catalog keys worth keeping. /StructTreeRoot and /MarkInfo are dropped:
    /// the tagged structure would no longer match the replaced content.
    private static let catalogKeys = [
        "Outlines", "Names", "Dests", "PageLabels", "ViewerPreferences", "PageMode",
        "PageLayout", "Lang", "Metadata", "OCProperties", "AcroForm",
    ]

    func reserve() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    /// Reserves the object number of a page dictionary and remembers it, so a
    /// later /Dest, /P or outline reference to that page resolves to the same
    /// object instead of starting a second copy of the page and its tree.
    func reservePage(_ dictionary: CGPDFDictionaryRef) -> Int {
        let key = unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
        if let id = memo[key] { return id }
        let id = reserve()
        memo[key] = id
        return id
    }

    // MARK: - Page tree and catalog

    func writePage(_ entry: PageEntry, parent: Int, replacement: [UInt8]?) {
        let dictionary = entry.dictionary
        var body = "<< /Type /Page /Parent \(parent) 0 R"
        // Inheritable attributes are resolved through /Parent and written here,
        // because the new page tree is flat.
        if let box = inherited("MediaBox", from: dictionary) {
            body += " /MediaBox \(object(box))"
        } else {
            body += " /MediaBox \(array(entry.page.getBoxRect(.mediaBox)))"
        }
        if let crop = inherited("CropBox", from: dictionary) { body += " /CropBox \(object(crop))" }
        if let rotate = inherited("Rotate", from: dictionary) { body += " /Rotate \(object(rotate))" }
        if let resources = inherited("Resources", from: dictionary) {
            body += " /Resources \(object(resources))"
        }
        if let replacement {
            let streamID = reserve()
            objects[streamID] = streamObject(dictionary: "/Filter /FlateDecode ",
                                             data: PDFZlib.compress(Data(replacement)))
            body += " /Contents \(streamID) 0 R"
        } else {
            var contents: CGPDFObjectRef? = nil
            if CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents {
                body += " /Contents \(object(contents))"
            }
        }
        body += entries(dictionary, skipping: Self.handledPageKeys)
        body += ">>"
        objects[entry.id] = Data(body.utf8)
    }

    func writePagesTree(_ kids: [Int], id: Int) {
        var body = "<< /Type /Pages /Kids ["
        for (index, kid) in kids.enumerated() {
            if index > 0 { body += " " }
            body += "\(kid) 0 R"
        }
        body += "] /Count \(kids.count) >>"
        objects[id] = Data(body.utf8)
    }

    func writeCatalog(_ catalog: CGPDFDictionaryRef?, pagesID: Int, id: Int) {
        var body = "<< /Type /Catalog /Pages \(pagesID) 0 R"
        if let catalog {
            for key in Self.catalogKeys {
                var value: CGPDFObjectRef? = nil
                if CGPDFDictionaryGetObject(catalog, key, &value), let value {
                    body += " \(name(key)) \(object(value))"
                }
            }
        }
        body += ">>"
        objects[id] = Data(body.utf8)
    }

    /// Looks a key up on the page and then on its ancestors.
    private func inherited(_ key: String, from dictionary: CGPDFDictionaryRef) -> CGPDFObjectRef? {
        var current: CGPDFDictionaryRef? = dictionary
        var depth = 0
        while let node = current, depth < 64 {
            var value: CGPDFObjectRef? = nil
            if CGPDFDictionaryGetObject(node, key, &value) { return value }
            var parent: CGPDFDictionaryRef? = nil
            current = CGPDFDictionaryGetDictionary(node, "Parent", &parent) ? parent : nil
            depth += 1
        }
        return nil
    }

    // MARK: - Objects

    /// Writes a dictionary as an indirect object and returns its number.
    func dictionary(_ dictionary: CGPDFDictionaryRef) -> Int {
        let key = unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
        if let id = memo[key] { return id }
        let id = reserve()
        memo[key] = id
        objects[id] = Data("<<\(entries(dictionary, skipping: []))>>".utf8)
        return id
    }

    /// Writes a stream as an indirect object and returns its number.
    private func stream(_ stream: CGPDFStreamRef) -> Int {
        let key = unsafeBitCast(stream, to: UnsafeRawPointer.self)
        if let id = memo[key] { return id }
        let id = reserve()
        memo[key] = id
        if let replacement = streamReplacements[key] {
            // The replacement is decoded content, so the old encoding keys go
            // away but the rest of the dictionary stays: a form keeps its BBox,
            // Matrix and Resources.
            var body = CGPDFStreamGetDictionary(stream).map { entries($0, skipping: Self.handledStreamKeys) } ?? ""
            body += " /Filter /FlateDecode"
            objects[id] = streamObject(dictionary: body + " ", data: PDFZlib.compress(Data(replacement)))
            return id
        }
        var format = CGPDFDataFormat.raw
        let decoded = CGPDFStreamCopyData(stream, &format).map { $0 as Data } ?? Data()
        var body = CGPDFStreamGetDictionary(stream).map { entries($0, skipping: Self.handledStreamKeys) } ?? ""
        let payload: Data
        switch format {
        case .jpegEncoded:
            body += " /Filter /DCTDecode"
            payload = decoded
        case .JPEG2000:
            body += " /Filter /JPXDecode"
            payload = decoded
        default:
            // Everything else arrives decoded, so the original filter and its
            // parameters no longer describe the bytes.
            body += " /Filter /FlateDecode"
            payload = PDFZlib.compress(decoded)
        }
        objects[id] = streamObject(dictionary: body + " ", data: payload)
        return id
    }

    /// Serializes one object. Dictionaries and streams become references to
    /// indirect objects, arrays are written inline.
    private func object(_ object: CGPDFObjectRef) -> String {
        switch CGPDFObjectGetType(object) {
        case .null:
            return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            return CGPDFObjectGetValue(object, .boolean, &value) && value != 0 ? "true" : "false"
        case .integer:
            var value: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &value) ? String(value) : "0"
        case .real:
            var value: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &value) ? number(Double(value)) : "0"
        case .name:
            var value: UnsafePointer<CChar>? = nil
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return "/" }
            return name(String(cString: value))
        case .string:
            var value: CGPDFStringRef? = nil
            guard CGPDFObjectGetValue(object, .string, &value), let value,
                  let bytes = CGPDFStringGetBytePtr(value) else { return "<>" }
            return hexString(bytes, count: CGPDFStringGetLength(value))
        case .array:
            var value: CGPDFArrayRef? = nil
            guard CGPDFObjectGetValue(object, .array, &value), let value else { return "[]" }
            return array(value)
        case .dictionary:
            var value: CGPDFDictionaryRef? = nil
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { return "null" }
            return "\(dictionary(value)) 0 R"
        case .stream:
            var value: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return "null" }
            return "\(stream(value)) 0 R"
        @unknown default:
            return "null"
        }
    }

    private func array(_ array: CGPDFArrayRef) -> String {
        var body = "["
        for index in 0..<CGPDFArrayGetCount(array) {
            if index > 0 { body += " " }
            var element: CGPDFObjectRef? = nil
            if CGPDFArrayGetObject(array, index, &element), let element {
                body += object(element)
            } else {
                body += "null"
            }
        }
        return body + "]"
    }

    private func array(_ rect: CGRect) -> String {
        "[" + [rect.minX, rect.minY, rect.maxX, rect.maxY].map { number(Double($0)) }.joined(separator: " ") + "]"
    }

    /// Dictionary entries as " /Key value" pairs, skipping the given keys.
    private func entries(_ dictionary: CGPDFDictionaryRef, skipping keys: Set<String>) -> String {
        var body = ""
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            let key = String(cString: key)
            if keys.contains(key) { return true }
            body += " \(self.name(key)) \(self.object(value))"
            return true
        }, nil)
        return body
    }

    private func streamObject(dictionary: String, data: Data) -> Data {
        var out = Data("<< \(dictionary)/Length \(data.count) >>\nstream\n".utf8)
        out.append(data)
        out.append(Data("\nendstream".utf8))
        return out
    }

    // MARK: - Lexical forms

    private func name(_ name: String) -> String {
        var out = "/"
        for byte in name.utf8 {
            if byte < 33 || byte > 126 || Self.nameDelimiters.contains(byte) {
                out += "#" + hexPair(byte)
            } else {
                out.append(Character(UnicodeScalar(byte)))
            }
        }
        return out
    }

    /// Reals with at most six decimals and never an exponent. Integral values
    /// are written as integers, which is what PDF readers expect.
    private func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", locale: Self.posixLocale, value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    private func hexString(_ bytes: UnsafePointer<UInt8>, count: Int) -> String {
        var out = "<"
        out.reserveCapacity(count * 2 + 2)
        for index in 0..<count { out += hexPair(bytes[index]) }
        return out + ">"
    }

    private func hexString(_ bytes: [UInt8]) -> String {
        var out = "<"
        out.reserveCapacity(bytes.count * 2 + 2)
        for byte in bytes { out += hexPair(byte) }
        return out + ">"
    }

    private func hexPair(_ byte: UInt8) -> String {
        String(decoding: [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]], as: UTF8.self)
    }

    // MARK: - File

    func output(root: Int, info: Int?) -> Data {
        var out = Data("%PDF-1.7\n".utf8)
        // A binary comment tells tools that the file is not plain text.
        out.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
        var offsets = [Int](repeating: 0, count: nextID)
        for id in 1..<nextID {
            offsets[id] = out.count
            out.append(Data("\(id) 0 obj\n".utf8))
            out.append(objects[id] ?? Data("null".utf8))
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        out.append(Data("xref\n0 \(nextID)\n0000000000 65535 f \n".utf8))
        for id in 1..<nextID {
            let offset = String(offsets[id])
            out.append(Data((String(repeating: "0", count: max(0, 10 - offset.count)) + offset + " 00000 n \n").utf8))
        }
        var trailer = "trailer\n<< /Size \(nextID) /Root \(root) 0 R"
        if let info { trailer += " /Info \(info) 0 R" }
        let identifier = hexString((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        trailer += " /ID [\(identifier) \(identifier)] >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(trailer.utf8))
        return out
    }
}
