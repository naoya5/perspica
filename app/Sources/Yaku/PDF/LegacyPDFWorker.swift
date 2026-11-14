import Foundation

/// The Python PDF worker of earlier versions. PDFs are now translated in the
/// app, so its environment (several hundred MB) and its private home, whose
/// caches hold translated text, are only leftovers to remove.
enum LegacyPDFWorker {
    static var leftovers: [URL] {
        [
            AppPaths.supportDirectory.appendingPathComponent("pdf-worker", isDirectory: true),
            AppPaths.supportDirectory.appendingPathComponent("pdf-worker-home", isDirectory: true),
        ]
    }

    /// Removes whatever is left. Returns false if something could not be removed.
    @discardableResult
    static func remove() -> Bool {
        var succeeded = true
        for url in leftovers where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                AppLog.write("pdf: removed the old PDF worker files at \(url.lastPathComponent)")
            } catch {
                succeeded = false
                AppLog.write("pdf: could not remove \(url.lastPathComponent) (\(error))")
            }
        }
        return succeeded
    }
}
