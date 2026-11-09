import Foundation
import PDFKit
import YakuCore

/// Checks a dropped or opened file before it becomes a job (SPEC 8.1).
///
/// `validate` opens the whole document with PDFKit, which takes a while for a
/// large scan, so callers run it through `validateInBackground` and keep the
/// main actor free.
enum PDFIntake {
    struct Accepted: Sendable {
        let url: URL
        /// The document title, used as the translation context (SPEC 5.2, F3).
        /// Whitespace is collapsed and the length is capped, like the
        /// selection path's context, because the title comes from the file.
        let title: String
        let pageCount: Int
        /// The language of the first pages' text, or nil when the document
        /// has no readable text (a scan) or the recogniser is unsure.
        let sourceLanguage: String?
    }

    enum Result: Sendable {
        case accepted(Accepted)
        case rejected(String)
    }

    /// The longest title that becomes the translation context.
    static let titleLimit = 200
    /// How many pages, and how many characters, the language is read from.
    static let languageSamplePages = 3
    static let languageSampleLength = 2000

    static func validateInBackground(_ url: URL) async -> Result {
        await Task.detached(priority: .userInitiated) { validate(url) }.value
    }

    static func validate(_ url: URL) -> Result {
        guard url.pathExtension.lowercased() == "pdf" else {
            return .rejected("PDF だけ対応しています")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .rejected("PDF を読めませんでした")
        }
        guard let document = PDFDocument(url: url) else {
            return .rejected("PDF を読めませんでした")
        }
        // SPEC 8.1: パスワード付きの PDF は断る.
        if document.isEncrypted || document.isLocked {
            return .rejected("パスワード付きの PDF は訳せません")
        }
        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = (metadataTitle?.isEmpty == false)
            ? metadataTitle!
            : url.deletingPathExtension().lastPathComponent
        return .accepted(Accepted(
            url: url,
            title: normalizedTitle(rawTitle),
            pageCount: document.pageCount,
            sourceLanguage: sourceLanguage(of: document)
        ))
    }

    static func normalizedTitle(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(titleLimit))
    }

    /// Reads the first pages' text and asks the same recogniser the panel uses.
    private static func sourceLanguage(of document: PDFDocument) -> String? {
        var sample = ""
        for index in 0..<min(document.pageCount, languageSamplePages) {
            guard let text = document.page(at: index)?.string else { continue }
            sample += text
            sample += "\n"
            if sample.count >= languageSampleLength { break }
        }
        sample = String(sample.prefix(languageSampleLength))
        guard sample.count >= LanguageDetector.shortTextLength else { return nil }
        let detection = LanguageDetector.detect(sample)
        guard detection.confidence >= LanguageDetector.lowConfidence else { return nil }
        return detection.code
    }

    /// A bookmark for the retry path, so a job survives a relaunch (SPEC 11).
    static func bookmark(for url: URL) -> Data {
        (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }

    static func resolve(_ bookmark: Data) -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}
