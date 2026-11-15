import CoreGraphics
import Foundation

/// Link annotations of a document, read so the output (which is drawn page by
/// page, and so loses annotations) can carry the same links.
public struct PDFLink: Sendable, Equatable {
    public enum Target: Sendable, Hashable {
        case url(URL)
        /// 0-based page index and the point the view should show, in that page's space.
        case page(Int, CGPoint)
    }

    /// The clickable area in page space.
    public var rect: CGRect
    public var target: Target

    public init(rect: CGRect, target: Target) {
        self.rect = rect
        self.target = target
    }
}

public enum PDFLinkReader {
    /// Links per 0-based page index.
    public static func links(in document: CGPDFDocument) -> [Int: [PDFLink]] {
        var pageIndex: [UnsafeRawPointer: Int] = [:]
        for index in 0..<document.numberOfPages {
            if let dictionary = document.page(at: index + 1)?.dictionary {
                pageIndex[unsafeBitCast(dictionary, to: UnsafeRawPointer.self)] = index
            }
        }
        let names = NamedDestinations(document)
        var result: [Int: [PDFLink]] = [:]
        for index in 0..<document.numberOfPages {
            guard let page = document.page(at: index + 1), let dictionary = page.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { continue }
            for position in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation,
                      name(annotation, "Subtype") == "Link", let rect = rect(annotation, "Rect") else { continue }
                if let target = target(of: annotation, names: names, pageIndex: pageIndex) {
                    result[index, default: []].append(PDFLink(rect: rect, target: target))
                }
            }
        }
        return result
    }

    static func target(of annotation: CGPDFDictionaryRef, names: NamedDestinations,
                       pageIndex: [UnsafeRawPointer: Int]) -> PDFLink.Target? {
        var action: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action {
            switch name(action, "S") {
            case "URI":
                if let uri = string(action, "URI"), let url = URL(string: uri) { return .url(url) }
                return nil
            case "GoTo":
                return destination(in: action, key: "D", names: names, pageIndex: pageIndex)
            default:
                return nil
            }
        }
        return destination(in: annotation, key: "Dest", names: names, pageIndex: pageIndex)
    }

    /// A destination is an explicit array `[page /XYZ left top zoom]` (or /Fit and
    /// friends), or a name or string looked up in the document's named destinations.
    static func destination(in dictionary: CGPDFDictionaryRef, key: String, names: NamedDestinations,
                            pageIndex: [UnsafeRawPointer: Int]) -> PDFLink.Target? {
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, key, &array), let array {
            return explicit(array, pageIndex: pageIndex)
        }
        let label = name(dictionary, key) ?? string(dictionary, key)
        guard let label, let array = names.lookup(label) else { return nil }
        return explicit(array, pageIndex: pageIndex)
    }

    static func explicit(_ array: CGPDFArrayRef, pageIndex: [UnsafeRawPointer: Int]) -> PDFLink.Target? {
        var page: CGPDFDictionaryRef?
        guard CGPDFArrayGetCount(array) >= 1, CGPDFArrayGetDictionary(array, 0, &page), let page,
              let index = pageIndex[unsafeBitCast(page, to: UnsafeRawPointer.self)] else { return nil }
        var left: CGPDFReal = 0
        var top: CGPDFReal = 0
        var kind: UnsafePointer<CChar>?
        if CGPDFArrayGetName(array, 1, &kind), let kind, String(cString: kind) == "XYZ" {
            _ = CGPDFArrayGetNumber(array, 2, &left)
            _ = CGPDFArrayGetNumber(array, 3, &top)
        }
        return .page(index, CGPoint(x: left, y: top))
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value,
              let bytes = CGPDFStringGetBytePtr(value) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value)), as: UTF8.self)
    }

    static func rect(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in 0..<4 { guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil } }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }
}

/// The catalog's /Dests dictionary and /Names /Dests name tree.
struct NamedDestinations {
    let dests: CGPDFDictionaryRef?
    let tree: CGPDFDictionaryRef?

    init(_ document: CGPDFDocument) {
        var dests: CGPDFDictionaryRef?
        var names: CGPDFDictionaryRef?
        var tree: CGPDFDictionaryRef?
        if let catalog = document.catalog {
            _ = CGPDFDictionaryGetDictionary(catalog, "Dests", &dests)
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
                _ = CGPDFDictionaryGetDictionary(names, "Dests", &tree)
            }
        }
        self.dests = dests
        self.tree = tree
    }

    func lookup(_ label: String) -> CGPDFArrayRef? {
        if let dests, let found = Self.destinationArray(in: dests, key: label) { return found }
        if let tree { return Self.search(tree, label, depth: 0) }
        return nil
    }

    /// A destination value is the array itself or a dictionary holding it under /D.
    static func destinationArray(in dictionary: CGPDFDictionaryRef, key: String) -> CGPDFArrayRef? {
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, key, &array) { return array }
        var holder: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, key, &holder), let holder,
           CGPDFDictionaryGetArray(holder, "D", &array) { return array }
        return nil
    }

    static func search(_ node: CGPDFDictionaryRef, _ label: String, depth: Int) -> CGPDFArrayRef? {
        guard depth < 32 else { return nil }
        var limits: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Limits", &limits), let limits, CGPDFArrayGetCount(limits) == 2,
           let low = string(limits, 0), let high = string(limits, 1), label < low || label > high {
            return nil
        }
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            var index = 0
            while index + 1 < CGPDFArrayGetCount(names) {
                if string(names, index) == label {
                    var array: CGPDFArrayRef?
                    if CGPDFArrayGetArray(names, index + 1, &array) { return array }
                    var holder: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(names, index + 1, &holder), let holder,
                       CGPDFDictionaryGetArray(holder, "D", &array) { return array }
                    return nil
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid, let found = search(kid, label, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    static func string(_ array: CGPDFArrayRef, _ index: Int) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFArrayGetString(array, index, &value), let value,
              let bytes = CGPDFStringGetBytePtr(value) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value)), as: UTF8.self)
    }
}
