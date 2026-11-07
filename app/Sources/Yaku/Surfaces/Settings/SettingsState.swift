import Observation

/// Which settings tab is showing, so `--demo-tab` can open one directly
/// (SPEC 15).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case engine
    case pdf
    case overlay
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "一般"
        case .shortcuts: "ショートカット"
        case .engine: "エンジン"
        case .pdf: "PDF"
        case .overlay: "画面翻訳"
        case .privacy: "プライバシー"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .engine: "cpu"
        case .pdf: "doc.text"
        case .overlay: "text.viewfinder"
        case .privacy: "lock"
        }
    }

    /// Accepts either the Japanese title or the raw value from `--demo-tab`.
    static func named(_ name: String) -> SettingsTab? {
        if let tab = SettingsTab(rawValue: name.lowercased()) { return tab }
        return allCases.first { $0.title == name }
    }
}

@MainActor
@Observable
final class SettingsState {
    static let shared = SettingsState()
    var tab: SettingsTab = .general
}
