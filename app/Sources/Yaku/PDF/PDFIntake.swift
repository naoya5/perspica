import Foundation
import PDFKit

/// Checks a dropped or opened file before it becomes a job (SPEC 8.1).
enum PDFIntake {
    struct Accepted {
        let url: URL
        /// The document title, used as the translation context (SPEC 5.2, F3).
        let title: String
        let pageCount: Int
    }

    enum Result {
        case accepted(Accepted)
        case rejected(String)
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
        let title = (metadataTitle?.isEmpty == false)
            ? metadataTitle!
            : url.deletingPathExtension().lastPathComponent
        return .accepted(Accepted(url: url, title: title, pageCount: document.pageCount))
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
