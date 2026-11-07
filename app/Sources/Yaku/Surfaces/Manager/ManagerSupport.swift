import AppKit
import SwiftUI
import YakuCore

/// Hosts `GlowLayerView` inside a SwiftUI view, so the manager's translation
/// pane can show the same processing light as the panel (SPEC 6.5) without a
/// `TimelineView` re-rendering the tree.
struct ProcessingGlowOverlay: NSViewRepresentable {
    var active: Bool
    var cornerRadius: CGFloat
    var cycleSeconds: Double

    func makeNSView(context: Context) -> GlowLayerView {
        let view = GlowLayerView()
        return view
    }

    func updateNSView(_ view: GlowLayerView, context: Context) {
        view.configure(
            active: active,
            cornerRadius: cornerRadius,
            cycleSeconds: cycleSeconds,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

/// Reports the `NSWindow` a SwiftUI scene is displayed in, so the app can put
/// the app back into `.accessory` when the last hand-opened window closes.
struct WindowProbe: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }
}

/// Shows the app in the Dock and ⌘Tab while a hand-opened window is up, and
/// hides it again when the last one closes (SPEC 4.4).
///
/// The close is noticed from the view's `onDisappear` rather than from
/// `NSWindow.willCloseNotification`: the notification's `object` cannot cross
/// into a main-actor closure under Swift 6's checking, and the view's own
/// lifecycle is enough here.
@MainActor
final class WindowActivation {
    static let shared = WindowActivation()

    func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        AppLog.write("window: appeared; activation policy regular visible=\(window.isVisible) "
            + "num=\(window.windowNumber) level=\(window.level.rawValue) active=\(NSApp.isActive)")
        // SwiftUI settles the scene's own window state right after the view
        // appears, which can undo the ordering above, so it is repeated once
        // the run loop has finished that pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.show(window)
        }
    }

    private func show(_ window: NSWindow) {
        guard window.isVisible == false || window.occlusionState.contains(.visible) == false else {
            AppLog.write("window: settle ok num=\(window.windowNumber)")
            return
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppLog.write("window: settle re-ordered num=\(window.windowNumber) "
            + "visible=\(window.isVisible) active=\(NSApp.isActive)")
    }

    /// Called when a hand-opened window goes away. The panel and the HUD are
    /// above the normal window level, so they do not keep the Dock icon alive.
    func windowDidDisappear() {
        let remaining = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        guard remaining.isEmpty else {
            AppLog.write("window: closed, \(remaining.count) still open")
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppLog.write("window: last one closed; activation policy accessory")
    }
}

/// The shared look of the manager's pages: a title, a one-line explanation and
/// a large, quiet icon.
struct ManagerPlaceholder: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// A short caption used above a group of controls in the manager and settings.
struct ManagerSectionLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
