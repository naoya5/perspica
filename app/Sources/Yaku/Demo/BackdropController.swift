import AppKit
import SwiftUI

/// A full-screen stand-in for the desktop picture.
///
/// SPEC 15 asks for the panel, HUD, island and overlay over a light and a dark
/// background. The glass picks up whatever is behind it, so a window-only
/// capture shows it over nothing (a flat grey). This draws a gradient with a
/// few soft shapes at a low window level, so a screen-region capture sees a
/// real background. It never changes the Mac's wallpaper, and it only appears
/// with `--demo-backdrop light|dark`.
@MainActor
final class BackdropController {
    private var windows: [NSWindow] = []

    /// Above every ordinary window (level 0) and below the app's own surfaces.
    ///
    /// The panel is an `NSPanel` with `isFloatingPanel = true`, which makes the
    /// window server report it at level 3 however high its `level` is set, so
    /// the backdrop has to sit below 3. Level 2 leaves the app's surfaces
    /// (3 and up) on top and still covers every other app.
    private static let level = NSWindow.Level(rawValue: 2)

    func show(_ appearance: String) {
        let dark = appearance == "dark"
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            // Named so `tools/winid.swift` can tell it apart from the app's
            // own surfaces when a capture has to pick one window.
            window.title = "YakuBackdrop"
            window.level = Self.level
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: BackdropView(dark: dark))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        AppLog.write("demo: backdrop \(appearance) on \(windows.count) screen(s)")
    }

    func close() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

/// The picture itself: a gradient plus soft shapes, which is what the glass
/// needs to show its blur and its highlight.
struct BackdropView: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(white: 0.07), Color(white: 0.24)]
                    : [Color(white: 0.99), Color(white: 0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            shape(Color(red: 0.16, green: 0.34, blue: 0.70), opacity: dark ? 0.55 : 0.40,
                  size: 760, x: -430, y: -250)
            shape(Color(red: 0.80, green: 0.32, blue: 0.36), opacity: dark ? 0.45 : 0.35,
                  size: 620, x: 380, y: -320)
            shape(Color(red: 0.20, green: 0.66, blue: 0.58), opacity: dark ? 0.42 : 0.32,
                  size: 700, x: 300, y: 330)
            shape(Color(red: 0.86, green: 0.66, blue: 0.22), opacity: dark ? 0.40 : 0.34,
                  size: 560, x: -380, y: 300)
        }
        .ignoresSafeArea()
    }

    private func shape(_ color: Color, opacity: Double, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: 110)
            .offset(x: x, y: y)
    }
}
