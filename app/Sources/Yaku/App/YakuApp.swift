import SwiftUI

/// The SwiftUI app. The menu bar item, the panel and the HUD stay AppKit
/// (`AppDelegate`), and the manager, the settings and the first-run guide are
/// scenes here so the sidebar and toolbar are macOS 26's own (SPEC 4.4).
@main
struct YakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("管理画面", id: WindowID.manager) {
            ManagerWindowView(
                coordinator: delegate.coordinator,
                model: delegate.managerModel,
                pdf: delegate.pdfQueue,
                state: ManagerState.shared,
                onChoosePDF: { delegate.choosePDF() }
            )
        }
        .defaultSize(width: 980, height: 640)
        // A menu bar app must not open a window just because it launched.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            // SPEC 12: ⌘1〜⌘5 pick the sidebar item. These are menu commands,
            // so they only fire while one of our windows is frontmost, which
            // is exactly when the manager is in use.
            CommandMenu("移動") {
                Button("翻訳") { ManagerState.shared.select(.translate) }
                    .keyboardShortcut("1")
                Button("PDF") { ManagerState.shared.select(.pdf) }
                    .keyboardShortcut("2")
                Button("履歴") { ManagerState.shared.select(.history) }
                    .keyboardShortcut("3")
                Button("用語集") { ManagerState.shared.select(.glossary) }
                    .keyboardShortcut("4")
                Button("モデル") { ManagerState.shared.select(.models) }
                    .keyboardShortcut("5")
            }
            CommandGroup(replacing: .newItem) {
                Button("管理画面を開く") {
                    WindowBridge.shared.openManager()
                }
                .keyboardShortcut("n")
            }
        }

        Window("Perspica へようこそ", id: WindowID.onboarding) {
            OnboardingView(
                model: delegate.managerModel,
                coordinator: delegate.coordinator,
                initialPage: delegate.demo.page.flatMap(Int.init) ?? 1
            )
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsRootView(
                settings: AppSettings.shared,
                model: delegate.managerModel,
                coordinator: delegate.coordinator,
                pdf: delegate.pdfQueue,
                state: SettingsState.shared
            )
        }
    }
}
