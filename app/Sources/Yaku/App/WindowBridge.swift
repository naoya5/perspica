import SwiftUI

/// Scene identifiers for the two windows the app opens by hand.
enum WindowID {
    static let manager = "manager"
    static let onboarding = "onboarding"
}

/// Lets the AppKit side open the SwiftUI windows (SPEC 4.4: the panel's
/// 「管理画面で開く」, the menu bar's right-click menu, and the first-run guide).
///
/// `openWindow` and `openSettings` only exist inside a scene's environment, so
/// a SwiftUI view captures them here once it has appeared. The panel is created
/// at launch and is the first view to do that.
@MainActor
@Observable
final class WindowBridge {
    static let shared = WindowBridge()

    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var openSettings: OpenSettingsAction?

    /// True once a view has captured the actions, so a launch-time open can be
    /// retried instead of being lost.
    var isReady = false

    private var pendingOpen: (id: String, action: @MainActor () -> Void)?

    func adopt(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        self.openWindow = openWindow
        self.openSettings = openSettings
        if !isReady {
            isReady = true
            AppLog.write("window bridge: captured openWindow/openSettings")
            if let pending = pendingOpen {
                pendingOpen = nil
                pending.action()
            }
        }
    }

    func openManager(page: ManagerSection? = nil) {
        if let page { ManagerState.shared.section = page }
        AppLog.write("window bridge: open manager page=\(ManagerState.shared.section.rawValue)")
        perform(id: WindowID.manager) { [weak self] in
            self?.openWindow?(id: WindowID.manager)
        }
    }

    func openOnboarding() {
        AppLog.write("window bridge: open onboarding")
        perform(id: WindowID.onboarding) { [weak self] in
            self?.openWindow?(id: WindowID.onboarding)
        }
    }

    func openSettingsWindow() {
        AppLog.write("window bridge: open settings")
        guard isReady else {
            pendingOpen = (id: "settings", action: { [weak self] in self?.openSettings?() })
            return
        }
        openSettings?()
    }

    private func perform(id: String, action: @escaping @MainActor () -> Void) {
        guard isReady, openWindow != nil else {
            AppLog.write("window bridge: \(id) queued until a view has appeared")
            pendingOpen = (id: id, action: action)
            return
        }
        action()
    }
}
