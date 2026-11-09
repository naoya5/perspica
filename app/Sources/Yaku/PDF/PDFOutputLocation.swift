import Foundation
import YakuCore

/// Where a finished PDF is written and what it is called (SPEC 8.3).
@MainActor
enum PDFOutputLocation {
    /// 元のファイルと同じフォルダ → 選んだフォルダ → `~/Downloads`, in that order.
    /// Every folder is tried, because a folder that looks writable can still
    /// refuse the file (a protected folder, a full or read-only volume).
    static func candidateDirectories(for input: URL) -> [URL] {
        let settings = AppSettings.shared
        var candidates: [URL] = []
        if settings.pdfOutputSameFolder {
            candidates.append(input.deletingLastPathComponent())
        }
        let chosen = settings.pdfOutputFolder
        if !chosen.isEmpty {
            candidates.append(URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath))
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        candidates.append(downloads)

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    struct Placed {
        let mono: URL?
        let dual: URL?
        /// The folders that were tried, for the failure message.
        let tried: [URL]
    }

    /// Renames what BabelDOC wrote (`….no_watermark.ja.mono.pdf`) to
    /// `<元>.ja.pdf` / `<元>.ja.対訳.pdf`, adding ` (2)` when taken. The first
    /// folder that takes the translated PDF also gets the side-by-side one.
    /// `mono == nil` means no folder took it; the source files are untouched.
    static func place(
        monoPath: String,
        dualPath: String,
        input: URL,
        makeDual: Bool
    ) -> Placed {
        let directories = candidateDirectories(for: input)
        for (index, directory) in directories.enumerated() {
            guard let mono = move(monoPath, named: PDFOutputName.mono(forInput: input.lastPathComponent), into: directory) else {
                continue
            }
            if index > 0 {
                AppLog.write("pdf: fell back to \(directory.path) for \(input.lastPathComponent)")
            }
            var dual: URL?
            if makeDual {
                dual = move(dualPath, named: PDFOutputName.dual(forInput: input.lastPathComponent), into: directory)
            }
            return Placed(mono: mono, dual: dual, tried: Array(directories.prefix(index + 1)))
        }
        return Placed(mono: nil, dual: nil, tried: directories)
    }

    private static func move(_ sourcePath: String, named preferred: String, into directory: URL) -> URL? {
        guard !sourcePath.isEmpty else { return nil }
        let source = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let name = PDFOutputName.unique(preferred: preferred) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            AppLog.write("pdf: output \(destination.path)")
            return destination
        } catch {
            // A cross-volume move fails with EXDEV; a copy is the way out.
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                try? FileManager.default.removeItem(at: source)
                AppLog.write("pdf: output (copied) \(destination.path)")
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
            AppLog.write("pdf: could not place the output at \(destination.path) (\(error))")
            return nil
        }
    }
}
