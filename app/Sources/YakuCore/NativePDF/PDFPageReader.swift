import CoreGraphics
import Foundation

/// One page read through its content streams and the form XObjects they draw.
/// Not `Sendable`: it keeps the CoreGraphics stream references of the forms.
public struct PDFPageReading {
    public var content: PDFPageContent
    /// The form stream behind each stream index of `content.streams`. Index 0,
    /// the page's own content, has no entry.
    public var formStreams: [Int: CGPDFStreamRef]

    public init(content: PDFPageContent, formStreams: [Int: CGPDFStreamRef] = [:]) {
        self.content = content
        self.formStreams = formStreams
    }
}

/// Reads a page and every form XObject it draws into glyphs and operators.
///
/// Many PDFs, including any page Quartz re-prints from another PDF, keep their
/// text inside form XObjects. A `Do` operand is only a name, so the forms have
/// to be resolved through the resources and read like the page itself.
public enum PDFPageReader {
    public static func read(_ page: CGPDFPage) -> PDFPageReading {
        let content = PDFRewriter.content(of: page)
        let registry = PDFFormRegistry(pageContent: content)
        let resources = NativePDFTranslator.inheritedDictionary("Resources", of: page)
        let fonts = resources.map { PDFFontReader.fonts(in: $0).mapValues { PDFFontDecoder($0) } } ?? [:]
        let kinds = resources.map { NativePDFTranslator.xobjectKinds(in: $0) } ?? [:]
        let resolver = PDFFormResolver(registry: registry, resources: resources)
        var interpreted = PDFContentInterpreter.interpret(content, fonts: fonts, xobjectKinds: kinds,
                                                         resolver: resolver)
        interpreted.streams = registry.streams
        return PDFPageReading(content: interpreted, formStreams: registry.formStreams)
    }

    /// The form XObjects of one resource scope, keyed by resource name.
    static func formStreams(in resources: CGPDFDictionaryRef?) -> [String: CGPDFStreamRef] {
        guard let resources, let xobjects = dictionary(resources, "XObject") else { return [:] }
        // CGPDFDictionaryApplyBlock takes a C function pointer, so the result
        // travels through a box instead of a captured variable.
        final class Box: @unchecked Sendable {
            var forms: [String: CGPDFStreamRef] = [:]
        }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { key, value, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let form = CGPDFStreamGetDictionary(stream),
                  name(form, "Subtype") == "Form" else { return true }
            box.forms[String(cString: key)] = stream
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.forms
    }

    static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef? = nil
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}

/// Resolves form names in one resource scope and reads each form stream once.
private struct PDFFormResolver: PDFFormResolving {
    let registry: PDFFormRegistry
    /// The form XObjects of this scope, by resource name.
    let forms: [String: CGPDFStreamRef]

    init(registry: PDFFormRegistry, resources: CGPDFDictionaryRef?) {
        self.registry = registry
        forms = PDFPageReader.formStreams(in: resources)
    }

    func form(named name: String) -> PDFFormSource? {
        guard let stream = forms[name] else { return nil }
        return registry.source(for: stream)
    }
}

/// Hands out one stream index per distinct form stream and reads it once.
///
/// The same form may be drawn on several pages, or under several names, so the
/// index is keyed by the stream itself rather than by the resource name.
private final class PDFFormRegistry {
    private struct FormData {
        var index: Int
        var content: [UInt8]
        var matrix: CGAffineTransform
        var fonts: [String: any PDFCharDecoding]
        var xobjectKinds: [String: PDFGraphic.Kind]
        /// The form's own resources, nil when it has none.
        var resources: CGPDFDictionaryRef?
    }

    private var data: [UnsafeRawPointer: FormData] = [:]
    /// Index 0 is the page's own content.
    private(set) var streams: [[UInt8]]
    private(set) var formStreams: [Int: CGPDFStreamRef] = [:]

    init(pageContent: [UInt8]) {
        streams = [pageContent]
    }

    func source(for stream: CGPDFStreamRef) -> PDFFormSource? {
        guard let form = read(stream) else { return nil }
        return PDFFormSource(index: form.index, content: form.content, matrix: form.matrix,
                             fonts: form.fonts, xobjectKinds: form.xobjectKinds,
                             resolver: form.resources.map { PDFFormResolver(registry: self, resources: $0) })
    }

    private func read(_ stream: CGPDFStreamRef) -> FormData? {
        let key = unsafeBitCast(stream, to: UnsafeRawPointer.self)
        if let form = data[key] { return form }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else { return nil }

        let index = streams.count
        let content = [UInt8](bytes as Data)
        streams.append(content)
        formStreams[index] = stream
        let resources = PDFPageReader.dictionary(dictionary, "Resources")
        let form = FormData(
            index: index,
            content: content,
            matrix: Self.matrix(dictionary),
            fonts: resources.map { PDFFontReader.fonts(in: $0).mapValues { PDFFontDecoder($0) } } ?? [:],
            xobjectKinds: resources.map { NativePDFTranslator.xobjectKinds(in: $0) } ?? [:],
            resources: resources
        )
        data[key] = form
        return form
    }

    /// The /Matrix of a form, which is the identity when the entry is absent.
    private static func matrix(_ dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
        var array: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array,
              CGPDFArrayGetCount(array) >= 6 else { return .identity }
        var values: [CGFloat] = []
        for index in 0..<6 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return .identity }
            values.append(CGFloat(value))
        }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                 d: values[3], tx: values[4], ty: values[5])
    }
}
