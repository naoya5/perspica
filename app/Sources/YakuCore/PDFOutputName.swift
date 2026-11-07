import Foundation

/// The names the finished PDFs get (SPEC 8.3).
///
/// BabelDOC writes `attention.no_watermark.ja.mono.pdf` and
/// `attention.no_watermark.ja.dual.pdf`; the app renames them to
/// `attention.ja.pdf` and `attention.ja.対訳.pdf`, and adds ` (2)` when the
/// name is already taken.
public enum PDFOutputName {
    /// `<元の名前>.ja.pdf`
    public static func mono(forInput fileName: String) -> String {
        stem(fileName) + ".ja.pdf"
    }

    /// `<元の名前>.ja.対訳.pdf`
    public static func dual(forInput fileName: String) -> String {
        stem(fileName) + ".ja.対訳.pdf"
    }

    /// Inserts ` (2)`, ` (3)`… before the extension until `exists` says the
    /// name is free. The first candidate is returned unchanged when it is free.
    public static func unique(preferred: String, exists: (String) -> Bool) -> String {
        guard exists(preferred) else { return preferred }
        let (base, suffix) = split(preferred)
        var index = 2
        while true {
            let candidate = "\(base) (\(index))\(suffix)"
            if !exists(candidate) { return candidate }
            index += 1
        }
    }

    /// `attention.pdf` → `attention`; a name without an extension is returned
    /// as it is.
    private static func stem(_ fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let name = url.lastPathComponent
        let ext = url.pathExtension
        guard !ext.isEmpty else { return name }
        return String(name.dropLast(ext.count + 1))
    }

    /// `attention.ja.pdf` → (`attention.ja`, `.pdf`).
    private static func split(_ fileName: String) -> (String, String) {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        guard !ext.isEmpty else { return (fileName, "") }
        return (String(fileName.dropLast(ext.count + 1)), "." + ext)
    }
}
