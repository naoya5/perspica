import Foundation
import Observation
import YakuCore

/// The app's preferences, in one place (SPEC 4.4).
///
/// Normally this is `UserDefaults.standard`. With `--data-dir` it becomes a
/// JSON file inside that folder instead: a separate `UserDefaults` suite would
/// write to `~/Library/Preferences`, which is outside the area a demo run is
/// allowed to touch. Either way the value of every key lives in `values`, so
/// the two backends behave identically.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Backend {
        case userDefaults
        case file(URL)
    }

    @ObservationIgnored private var backend: Backend = .userDefaults
    /// The in-memory mirror of the backend; every property reads and writes it.
    private var values: [String: Any] = [:]

    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let defaultTargetLanguage = "defaultTargetLanguage"
        static let defaultForm = "defaultForm"
        static let autoTranslate = "autoTranslate"
        static let useNotch = "useNotch"
        static let selectionShortcut = "shortcut.selection"
        static let panelShortcut = "shortcut.panel"
        static let screenShortcut = "shortcut.screen"
        static let engineIdleMinutes = "engineIdleMinutes"
        static let selectedModelID = "selectedModelID"
        static let modelPath = "modelPath"
        static let pdfOutputSameFolder = "pdfOutputSameFolder"
        static let pdfOutputFolder = "pdfOutputFolder"
        static let pdfOpenWhenDone = "pdfOpenWhenDone"
        static let pdfMakeDual = "pdfMakeDual"
        static let pdfPythonPath = "pdfPythonPath"
        static let overlayLanguage = "overlayLanguage"
        static let overlayMinScale = "overlayMinScale"
        static let keepHistory = "keepHistory"
        static let historyRetentionDays = "historyRetentionDays"
        static let licenseConsent = "licenseConsent"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let manualPairSource = "manualPairSource"
        static let manualPairTarget = "manualPairTarget"

        /// Only these keys are read back, so the store never picks up unrelated
        /// system defaults that happen to share a name.
        static let all: [String] = [
            launchAtLogin, defaultTargetLanguage, defaultForm, autoTranslate, useNotch,
            selectionShortcut, panelShortcut, screenShortcut,
            engineIdleMinutes, selectedModelID, modelPath,
            pdfOutputSameFolder, pdfOutputFolder, pdfOpenWhenDone, pdfMakeDual, pdfPythonPath,
            overlayLanguage, overlayMinScale,
            keepHistory, historyRetentionDays,
            licenseConsent, hasSeenOnboarding,
            manualPairSource, manualPairTarget,
        ]
    }

    private init() {
        // `--data-dir` keeps the settings in a JSON file inside that folder, so
        // a demo run starts as a brand new user. A separate `UserDefaults`
        // suite would write to ~/Library/Preferences, outside the folder.
        if let value = LaunchArguments.dataDirectory, !value.isEmpty {
            let directory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            backend = .file(directory.appendingPathComponent("settings.json"))
        }
        load()
    }

    /// Switches to a JSON file in `directory` and reloads everything from it.
    func useDataDirectory(_ directory: URL) {
        backend = .file(directory.appendingPathComponent("settings.json"))
        values = [:]
        load()
    }

    private func load() {
        switch backend {
        case .userDefaults:
            for key in Key.all {
                if let value = UserDefaults.standard.object(forKey: key) {
                    values[key] = value
                }
            }
        case .file(let url):
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            for key in Key.all where object[key] != nil {
                values[key] = object[key]
            }
        }
    }

    private func store(_ key: String, _ value: Any) {
        values[key] = value
        switch backend {
        case .userDefaults:
            UserDefaults.standard.set(value, forKey: key)
        case .file(let url):
            let data = (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]))
                ?? Data()
            try? data.write(to: url)
        }
    }

    private func remove(_ key: String) {
        values.removeValue(forKey: key)
        switch backend {
        case .userDefaults:
            UserDefaults.standard.removeObject(forKey: key)
        case .file(let url):
            let data = (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]))
                ?? Data()
            try? data.write(to: url)
        }
    }

    private func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if let value = values[key] as? Bool { return value }
        if let number = values[key] as? NSNumber { return number.boolValue }
        return fallback
    }

    private func integer(_ key: String, default fallback: Int) -> Int {
        if let number = values[key] as? NSNumber { return number.intValue }
        return fallback
    }

    private func double(_ key: String, default fallback: Double) -> Double {
        if let number = values[key] as? NSNumber { return number.doubleValue }
        return fallback
    }

    private func string(_ key: String) -> String? {
        values[key] as? String
    }

    // MARK: 一般

    var launchAtLogin: Bool {
        get { bool(Key.launchAtLogin) }
        set { store(Key.launchAtLogin, newValue) }
    }

    var defaultTargetLanguage: String {
        get { string(Key.defaultTargetLanguage) ?? "ja" }
        set { store(Key.defaultTargetLanguage, newValue) }
    }

    var defaultForm: TranslationForm {
        get { TranslationForm(rawValue: string(Key.defaultForm) ?? "") ?? .plain }
        set { store(Key.defaultForm, newValue.rawValue) }
    }

    var autoTranslate: Bool {
        get { bool(Key.autoTranslate, default: true) }
        set { store(Key.autoTranslate, newValue) }
    }

    var useNotch: Bool {
        get { bool(Key.useNotch, default: true) }
        set { store(Key.useNotch, newValue) }
    }

    // MARK: ショートカット

    private func shortcut(_ key: String, default fallback: Shortcut) -> Shortcut {
        guard let text = string(key) else { return fallback }
        return ShortcutCodec.decode(text) ?? fallback
    }

    private func setShortcut(_ shortcut: Shortcut?, _ key: String) {
        guard let shortcut else {
            remove(key)
            return
        }
        store(key, ShortcutCodec.encode(shortcut))
    }

    var selectionShortcut: Shortcut {
        get { shortcut(Key.selectionShortcut, default: ShortcutDefaults.selection) }
        set { setShortcut(newValue, Key.selectionShortcut) }
    }

    var panelShortcut: Shortcut {
        get { shortcut(Key.panelShortcut, default: ShortcutDefaults.panel) }
        set { setShortcut(newValue, Key.panelShortcut) }
    }

    var screenShortcut: Shortcut {
        get { shortcut(Key.screenShortcut, default: ShortcutDefaults.screen) }
        set { setShortcut(newValue, Key.screenShortcut) }
    }

    var shortcutBindings: [ShortcutBinding] {
        [
            ShortcutBinding(id: ShortcutDefaults.selectionID, shortcut: selectionShortcut),
            ShortcutBinding(id: ShortcutDefaults.panelID, shortcut: panelShortcut),
            ShortcutBinding(id: ShortcutDefaults.screenID, shortcut: screenShortcut),
        ]
    }

    // MARK: エンジン

    /// Minutes of idle time before the engine is stopped; 0 means never.
    var engineIdleMinutes: Int {
        get { integer(Key.engineIdleMinutes, default: 10) }
        set { store(Key.engineIdleMinutes, newValue) }
    }

    var engineIdleSeconds: Double {
        engineIdleMinutes <= 0 ? 0 : Double(engineIdleMinutes) * 60
    }

    var selectedModelID: String {
        get { string(Key.selectedModelID) ?? ModelCatalog.defaultModelID }
        set { store(Key.selectedModelID, newValue) }
    }

    /// A file the user picked by hand (the `modelPath` setting).
    var customModelPath: String {
        get { string(Key.modelPath) ?? "" }
        set { store(Key.modelPath, newValue) }
    }

    // MARK: PDF (SPEC 4.4)

    var pdfOutputSameFolder: Bool {
        get { bool(Key.pdfOutputSameFolder, default: true) }
        set { store(Key.pdfOutputSameFolder, newValue) }
    }

    /// The folder used when 「元のファイルと同じ場所」 is off.
    var pdfOutputFolder: String {
        get { string(Key.pdfOutputFolder) ?? "" }
        set { store(Key.pdfOutputFolder, newValue) }
    }

    var pdfOpenWhenDone: Bool {
        get { bool(Key.pdfOpenWhenDone, default: true) }
        set { store(Key.pdfOpenWhenDone, newValue) }
    }

    var pdfMakeDual: Bool {
        get { bool(Key.pdfMakeDual, default: true) }
        set { store(Key.pdfMakeDual, newValue) }
    }

    /// The interpreter the PDF worker runs with; empty means the installed
    /// environment (SPEC 8.2: 開発中は lab の .venv を使える).
    var pdfPythonPath: String {
        get { string(Key.pdfPythonPath) ?? "" }
        set { store(Key.pdfPythonPath, newValue) }
    }

    // MARK: 画面翻訳（表示だけの項目）

    var overlayLanguage: String {
        get { string(Key.overlayLanguage) ?? "auto" }
        set { store(Key.overlayLanguage, newValue) }
    }

    var overlayMinScale: Double {
        get { double(Key.overlayMinScale, default: 0.7) }
        set { store(Key.overlayMinScale, newValue) }
    }

    // MARK: プライバシー

    var keepHistory: Bool {
        get { bool(Key.keepHistory, default: true) }
        set { store(Key.keepHistory, newValue) }
    }

    /// 30 / 90 / 0 (ずっと).
    var historyRetentionDays: Int {
        get { integer(Key.historyRetentionDays, default: 90) }
        set { store(Key.historyRetentionDays, newValue) }
    }

    // MARK: ライセンスと初回の案内

    var licenseConsent: Set<String> {
        get { Set((string(Key.licenseConsent) ?? "").split(separator: ",").map(String.init)) }
        set { store(Key.licenseConsent, newValue.sorted().joined(separator: ",")) }
    }

    func hasAcceptedLicense(for modelID: String) -> Bool {
        licenseConsent.contains(modelID)
    }

    func acceptLicense(for modelID: String) {
        var consent = licenseConsent
        consent.insert(modelID)
        licenseConsent = consent
    }

    var hasSeenOnboarding: Bool {
        get { bool(Key.hasSeenOnboarding) }
        set { store(Key.hasSeenOnboarding, newValue) }
    }

    // MARK: 言語の組み合わせ（手で選んだとき）

    var manualPairSource: String {
        get { string(Key.manualPairSource) ?? "" }
        set { store(Key.manualPairSource, newValue) }
    }

    var manualPairTarget: String {
        get { string(Key.manualPairTarget) ?? "" }
        set { store(Key.manualPairTarget, newValue) }
    }
}

/// The three global shortcuts (SPEC 12).
public enum ShortcutDefaults {
    public static let selectionID = "selection"
    public static let panelID = "panel"
    public static let screenID = "screen"

    /// ⌃⌥J — 10 is the virtual key code for J.
    public static let selection = Shortcut(keyCode: 38, modifiers: [.control, .option])
    /// ⌃⌥K
    public static let panel = Shortcut(keyCode: 40, modifiers: [.control, .option])
    /// ⌃⌥O
    public static let screen = Shortcut(keyCode: 31, modifiers: [.control, .option])

    public static func displayName(for id: String) -> String {
        switch id {
        case selectionID: "選択文を訳す"
        case panelID: "パネルを開く"
        default: "画面を翻訳"
        }
    }
}
