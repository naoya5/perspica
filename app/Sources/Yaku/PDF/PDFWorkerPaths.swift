import Foundation
import YakuCore

/// Where the PDF worker's scripts, Python and private files live (SPEC 8.2).
///
/// The scripts ship inside the app bundle (`Contents/Resources/pdf-worker`);
/// during development the repository copy is used when the bundle has none.
/// The Python environment is installed into Application Support the first time
/// a PDF arrives, and a `--pdf-python` path (or the settings field) overrides it
/// with an interpreter of the developer's own.
///
/// The worker also gets a private home folder next to the environment. pdf2zh
/// and BabelDOC keep their files under `$HOME/.cache` (the translation cache
/// holds every paragraph and its translation, the assets are fonts and the
/// layout model), so pointing `HOME` there keeps them inside the app's own
/// data, where 「削除」 and the privacy controls reach them.
@MainActor
enum PDFWorkerPaths {
    /// `uv` is the only way the environment is created (SPEC 8.2).
    static var uvPath: String? { ExecutableLocator.find("uv") }

    /// The repository's copy, used when the app runs from a build folder
    /// rather than a bundle. Derived from this source file's location at
    /// compile time, so it points at whichever checkout built the app.
    static let developmentScriptsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PDF
        .deletingLastPathComponent()  // Yaku
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()  // repository
        .appendingPathComponent("pdf-worker")
        .path

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

    /// The compiled, hashed lock file the installer syncs the environment to.
    static var requirementsFile: URL? {
        scriptsDirectory?.appendingPathComponent("requirements.txt")
    }

    /// `~/Library/Application Support/Yaku/pdf-worker` (or the `--data-dir` folder).
    static var environmentDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("pdf-worker")
    }

    /// The worker's `HOME`: `pdf-worker-home` next to the environment.
    static var privateHomeDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("pdf-worker-home")
    }

    /// pdf2zh's translation cache (every paragraph and its translation) and
    /// BabelDOC's, both SQLite files under the private home.
    static var translationCacheLocations: [URL] {
        let cache = privateHomeDirectory.appendingPathComponent(".cache")
        return [
            cache.appendingPathComponent("pdf2zh_next"),
            cache.appendingPathComponent("babeldoc/cache.v1.db"),
        ]
    }

    static var installedPython: URL {
        environmentDirectory.appendingPathComponent("bin/python")
    }

    /// The hash of the requirements the environment was last synced to. A
    /// missing or different stamp means the environment has to be synced
    /// before the next PDF, which is how an existing installation picks up a
    /// dependency fix.
    static var requirementsStamp: URL {
        environmentDirectory.appendingPathComponent("requirements.sha256")
    }

    static func requirementsHash() -> String? {
        guard let requirementsFile else { return nil }
        return try? FileHash.sha256(ofFileAt: requirementsFile)
    }

    static func writeRequirementsStamp() {
        guard let hash = requirementsHash() else { return }
        try? hash.write(to: requirementsStamp, atomically: true, encoding: .utf8)
    }

    /// True when the installed environment matches the shipped requirements.
    static var installedEnvironmentIsCurrent: Bool {
        guard let want = requirementsHash(),
              let have = try? String(contentsOf: requirementsStamp, encoding: .utf8)
        else { return false }
        return have.trimmingCharacters(in: .whitespacesAndNewlines) == want
    }

    /// What has to happen before a PDF can run.
    enum Readiness: Equatable {
        /// This interpreter runs the worker.
        case ready(URL)
        /// Nothing is installed yet (SPEC 8.2: ask first).
        case needsInstall
        /// The environment exists but was synced to older requirements.
        case needsUpdate
    }

    /// The setting's interpreter is the developer's own and is never synced;
    /// the installed environment has to match the shipped requirements.
    static var readiness: Readiness {
        let custom = AppSettings.shared.pdfPythonPath
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return .ready(URL(fileURLWithPath: custom))
        }
        guard isInstalledEnvironmentPresent else { return .needsInstall }
        return installedEnvironmentIsCurrent ? .ready(installedPython) : .needsUpdate
    }

    /// The interpreter the worker runs with: the setting, else the installed
    /// environment. `nil` means it has to be installed first.
    static var pythonExecutable: URL? {
        if case .ready(let python) = readiness { return python }
        return nil
    }

    /// Demo only (`--demo-pdf-worker installed`): report the environment as
    /// installed so the settings tab's 導入済み state can be photographed
    /// without the ~1GB download, which needs the network (SPEC 15).
    static var demoInstalled = false

    /// True when the environment exists, whatever interpreter it is using.
    static var isInstalled: Bool {
        demoInstalled || isInstalledEnvironmentPresent
    }

    static var uvIsAvailable: Bool {
        uvPath != nil
    }

    /// The size of the installed environment, which goes into the wording
    /// (SPEC 13: 「約 ___MB」).
    static var installedBytes: Int64 {
        if demoInstalled, !isInstalledEnvironmentPresent {
            // A plausible figure for the demo, from the measured install.
            return PDFWorkerInstaller.estimatedBytes
        }
        guard isInstalled else { return 0 }
        return directorySize(environmentDirectory)
    }

    private static var isInstalledEnvironmentPresent: Bool {
        FileManager.default.isExecutableFile(atPath: installedPython.path)
    }

    /// 「削除」: the environment and the worker's private home, caches and all.
    static func removeInstallation() {
        for folder in [environmentDirectory, privateHomeDirectory]
        where FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.removeItem(at: folder)
            AppLog.write("pdf-worker: removed \(folder.path)")
        }
    }

    /// Deletes the paragraph-level translation caches and keeps the assets
    /// (fonts, layout model), so the next PDF does not download them again.
    static func clearTranslationCache() {
        for location in translationCacheLocations
        where FileManager.default.fileExists(atPath: location.path) {
            try? FileManager.default.removeItem(at: location)
            AppLog.write("pdf-worker: removed the translation cache at \(location.path)")
        }
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
