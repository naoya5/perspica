import Foundation
import YakuCore

/// Where a finished PDF is written and what it is called (SPEC 8.3).
@MainActor
enum PDFOutputLocation {
    /// 元のファイルと同じフォルダ → 選んだフォルダ → `~/Downloads`.
    static func destinationDirectory(for input: URL) -> URL {
        let settings = AppSettings.shared
        let inputDirectory = input.deletingLastPathComponent()

        if settings.pdfOutputSameFolder, FileManager.default.isWritableFile(atPath: inputDirectory.path) {
            return inputDirectory
        }
        let chosen = settings.pdfOutputFolder
        if !chosen.isEmpty {
            let url = URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
            if FileManager.default.isWritableFile(atPath: url.path) { return url }
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        AppLog.write("pdf: fell back to ~/Downloads for \(input.lastPathComponent)")
        return downloads
    }

    struct Placed {
        let mono: URL?
        let dual: URL?
    }

    /// Renames what BabelDOC wrote (`….no_watermark.ja.mono.pdf`) to
    /// `<元>.ja.pdf` / `<元>.ja.対訳.pdf`, adding ` (2)` when taken.
    static func place(
        monoPath: String,
        dualPath: String,
        input: URL,
        makeDual: Bool
    ) -> Placed {
        let directory = destinationDirectory(for: input)
        let mono = move(monoPath, named: PDFOutputName.mono(forInput: input.lastPathComponent), into: directory)
        var dual: URL?
        if makeDual {
            dual = move(dualPath, named: PDFOutputName.dual(forInput: input.lastPathComponent), into: directory)
        }
        return Placed(mono: mono, dual: dual)
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
            AppLog.write("pdf: could not place the output at \(destination.path) (\(error))")
            return nil
        }
    }
}
