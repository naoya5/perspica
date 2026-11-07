import Foundation
import YakuCore

/// Where the model files live and which one the app should use (SPEC 7.5).
@MainActor
enum ModelStore {
    static func installedURL(for model: TranslationModel) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// The file being downloaded; kept when a download is cancelled so it can
    /// be resumed (SPEC 7.5: 途中から再開できる).
    static func partialURL(for model: TranslationModel) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(model.fileName + ".partial")
    }

    static func isInstalled(_ model: TranslationModel) -> Bool {
        installedBytes(model) == model.bytes
    }

    static func installedBytes(_ model: TranslationModel) -> Int64 {
        byteCount(at: installedURL(for: model))
    }

    static func partialBytes(_ model: TranslationModel) -> Int64 {
        byteCount(at: partialURL(for: model))
    }

    private static func byteCount(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    static func delete(_ model: TranslationModel) {
        try? FileManager.default.removeItem(at: installedURL(for: model))
        try? FileManager.default.removeItem(at: partialURL(for: model))
        AppLog.write("models: deleted \(model.fileName)")
    }

    /// Goes into the cache key, so switching models does not reuse a
    /// translation produced by a different one (SPEC 5.3).
    static func cacheKey() -> String {
        let settings = AppSettings.shared
        if !settings.customModelPath.isEmpty {
            return "custom:" + settings.customModelPath
        }
        return ModelCatalog.model(id: settings.selectedModelID)?.id ?? ModelCatalog.defaultModelID
    }

    /// M0's development file, used when nothing has been downloaded yet.
    static let developmentModelPath = "/Users/naoya/docs/agentic-os/lab/plamo-pdf-translate/models/"
        + "plamo-3-translate-0.8b-GGUF/plamo-3-translate-0.8b-Q4_K_M.gguf"

    struct Resolution {
        let path: String
        let label: String
        /// Which catalogue entry this file is, when it is one of them.
        let model: TranslationModel?
    }

    /// True when `resolve()` is falling back to M0's development file, which
    /// happens on this Mac because the 0.8B file has never been downloaded
    /// (SPEC 15, M5: the model page has to say so instead of 「未取得」).
    static var isUsingDevelopmentFile: Bool {
        let settings = AppSettings.shared
        let custom = settings.customModelPath
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) { return false }
        let selected = ModelCatalog.model(id: settings.selectedModelID) ?? ModelCatalog.models[0]
        guard !isInstalled(selected) else { return false }
        return FileManager.default.fileExists(atPath: developmentModelPath)
    }

    /// The model the engine should load:
    /// a file the user picked → the selected model's download → M0's file.
    static func resolve() -> Resolution? {
        let settings = AppSettings.shared

        let custom = settings.customModelPath
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            return Resolution(path: custom, label: "選択したファイル", model: nil)
        }

        let selected = ModelCatalog.model(id: settings.selectedModelID) ?? ModelCatalog.models[0]
        if isInstalled(selected) {
            return Resolution(path: installedURL(for: selected).path, label: selected.displayName, model: selected)
        }

        if FileManager.default.fileExists(atPath: developmentModelPath) {
            return Resolution(
                path: developmentModelPath,
                label: ModelCatalog.models[0].displayName + "（開発用のファイル）",
                model: ModelCatalog.models[0]
            )
        }
        return nil
    }
}
