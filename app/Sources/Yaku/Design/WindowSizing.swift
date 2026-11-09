import AppKit
import SwiftUI

/// Sizes the settings window to the height its content wants, keeping the top
/// edge where it is, so the window follows the tab it is showing instead of
/// staying as tall as the tallest one.
///
/// The window uses a full-size content view, so its frame and its content view
/// are the same rectangle, and the titlebar and the tab bar are drawn *over* the
/// content as a safe-area inset. The target frame is therefore the measured
/// content height plus `safeAreaInsets.top` (88 pt: the titlebar and the tab
/// bar), which is also the height SwiftUI itself would choose.
///
/// The frame is set from a debounced task rather than during the SwiftUI
/// update: the first layout reports its height twice (the scene's own pass,
/// then the tab's), and applying both would show a small jump on open. Only the
/// settled height is applied, and only when it actually changed, so setting the
/// frame cannot feed another update.
struct SettingsWindowSizer: NSViewRepresentable {
    var contentHeight: CGFloat
    var width: CGFloat

    /// How long to wait for the height to settle. One run loop turn is not
    /// enough; 50 ms is below noticing and well above the burst.
    private static let settleDelay: TimeInterval = 0.05

    final class Coordinator {
        var lastHeight: CGFloat = 0
        var lastWidth: CGFloat = 0
        var didApplyOnce = false
        var pending: DispatchWorkItem?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = contentHeight
        let width = width
        guard height > 0 else { return }
        let coordinator = context.coordinator
        guard abs(coordinator.lastHeight - height) > 0.5
            || abs(coordinator.lastWidth - width) > 0.5 else { return }

        coordinator.pending?.cancel()
        let work = DispatchWorkItem { [weak view] in
            guard let window = view?.window else { return }
            coordinator.lastHeight = height
            coordinator.lastWidth = width
            // The first application settles the window on open, so it is not
            // animated; a tab switch after that is (the change is smooth).
            let animated = coordinator.didApplyOnce
            coordinator.didApplyOnce = true
            Self.apply(to: window, contentHeight: height, width: width, animated: animated)
        }
        coordinator.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private static func apply(to window: NSWindow, contentHeight: CGFloat, width: CGFloat,
                              animated: Bool) {
        // The chrome is drawn over the content, so it is added to the content
        // height rather than taken out of it.
        let chrome = window.contentView?.safeAreaInsets.top ?? 0
        var frame = window.frame
        frame.size = NSSize(width: width, height: contentHeight + chrome)
        // Grow downward: the titlebar stays put and the bottom edge moves.
        frame.origin.y = window.frame.maxY - frame.size.height
        window.setFrame(frame, display: true, animate: animated)
        AppLog.write(String(
            format: "settings: window %.0fx%.0f for content %.0f (chrome %.0f, animated %@)",
            frame.size.width, frame.size.height, contentHeight, chrome, animated ? "yes" : "no"
        ))
    }
}

/// Reads the height the content laid out at, so `SettingsRootView` can hand it
/// to `SettingsWindowSizer`.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's laid-out height through `ContentHeightKey`.
    func measureContentHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
    }
}
