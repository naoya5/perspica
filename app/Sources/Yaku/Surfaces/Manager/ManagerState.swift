import Foundation
import Observation

/// The five pages of the manager window (SPEC 4.4), and which one is showing.
enum ManagerSection: String, CaseIterable, Identifiable {
    case translate
    case pdf
    case history
    case glossary
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: "翻訳"
        case .pdf: "PDF"
        case .history: "履歴"
        case .glossary: "用語集"
        case .models: "モデル"
        }
    }

    var systemImage: String {
        switch self {
        case .translate: "character.bubble"
        case .pdf: "doc.text"
        case .history: "clock"
        case .glossary: "character.book.closed"
        case .models: "shippingbox"
        }
    }

    /// ⌘1〜⌘5 (SPEC 12).
    var shortcutDigit: Int {
        switch self {
        case .translate: 1
        case .pdf: 2
        case .history: 3
        case .glossary: 4
        case .models: 5
        }
    }

    static func forShortcutDigit(_ digit: Int) -> ManagerSection? {
        allCases.first { $0.shortcutDigit == digit }
    }
}

/// State shared by the manager window and the AppKit side (⌘1〜⌘5, opening a
/// page directly).
@MainActor
@Observable
final class ManagerState {
    static let shared = ManagerState()

    var section: ManagerSection = .translate
    /// Set by the history view's 「用語集に足す」 form.
    var glossaryDraftSource = ""
    var glossaryDraftTarget = ""
    var showsGlossaryDraft = false

    func select(_ section: ManagerSection) {
        self.section = section
        AppLog.write("manager: page \(section.rawValue)")
    }
}
