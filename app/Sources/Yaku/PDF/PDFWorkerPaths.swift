import Foundation

/// Where the PDF worker's scripts and Python live (SPEC 8.2).
///
/// The scripts ship inside the app bundle (`Contents/Resources/pdf-worker`);
/// during development the repository copy is used when the bundle has none.
/// The Python environment is installed into Application Support the first time
/// a PDF arrives, and a `--pdf-python` path (or the settings field) overrides it
/// so the prototype's `lab/plamo-pdf-translate/.venv` can be used.
@MainActor
enum PDFWorkerPaths {
    /// `uv` is the only way the environment is created (SPEC 8.2).
    static let uvPath = "/opt/homebrew/bin/uv"

    /// The checked-in fallback used while developing, mirroring
    /// `ModelStore.developmentModelPath`.
    static let developmentScriptsDirectory =
        "/Users/naoya/docs/agentic-os/projects/translate-app/pdf-worker"

    static var scriptsDirectory: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/pdf-worker")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("translate_pdf.py").path) {
            return bundled
        }
        let development = URL(fileURLWithPath: developmentScriptsDirectory)
        if FileManager.default.fileExists(atPath: development.appendingPathComponent("translate_pdf.py").path) {
            return development
        }
        return nil
    }

    static var translateScript: URL? {
        scriptsDirectory?.appendingPathComponent("translate_pdf.py")
    }

    static var requirementsFile: URL? {
        scriptsDirectory?.appendingPathComponent("requirements.txt")
    }

    /// `~/Library/Application Support/Yaku/pdf-worker` (or the `--data-dir` folder).
    static var environmentDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("pdf-worker")
    }

    static var installedPython: URL {
        environmentDirectory.appendingPathComponent("bin/python")
    }

    /// The interpreter the worker runs with: the setting, else the installed
    /// environment. `nil` means it has to be installed first.
    static var pythonExecutable: URL? {
        let custom = AppSettings.shared.pdfPythonPath
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if FileManager.default.isExecutableFile(atPath: installedPython.path) {
            return installedPython
        }
        return nil
    }

    /// True when the environment exists, whatever interpreter it is using.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedPython.path)
    }

    static var uvIsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: uvPath)
    }

    /// The size of the installed environment, which goes into the wording
    /// (SPEC 13: 「約 ___MB」).
    static var installedBytes: Int64 {
        guard isInstalled else { return 0 }
        return directorySize(environmentDirectory)
    }

    static func removeInstallation() {
        guard isInstalled else { return }
        try? FileManager.default.removeItem(at: environmentDirectory)
        AppLog.write("pdf-worker: removed the environment at \(environmentDirectory.path)")
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
