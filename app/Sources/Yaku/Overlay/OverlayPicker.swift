import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// What a click in the picker selects (SPEC 4.6 の 1).
enum OverlayPickMode: String, CaseIterable, Identifiable {
    case window
    case region
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "ウィンドウ"
        case .region: "範囲"
        case .fullScreen: "画面全体"
        }
    }
}

/// State of the region picker. Rects are in the picker window's own AppKit
/// coordinates (origin at the window's bottom left).
@MainActor
@Observable
final class OverlayPickerModel {
    var mode: OverlayPickMode = .window
    var screenSize: CGSize = .zero
    /// The mouse, window-local.
    var cursor: CGPoint = .zero
    /// The window under the cursor, drawn with a 1pt white outline.
    var windowRect: CGRect?
    /// The region being dragged out.
    var dragRect: CGRect?
    /// The glass capsule, so a click on it is not taken as a selection.
    var capsuleRect: CGRect = .zero

    /// The rect the current mode would select on a click.
    var activeRect: CGRect? {
        switch mode {
        case .window: windowRect
        case .region: dragRect
        case .fullScreen: CGRect(origin: .zero, size: screenSize)
        }
    }

    /// The outline to draw: the drag while dragging, otherwise the mode's own.
    var outlineRect: CGRect? {
        dragRect ?? activeRect
    }

    var isDragging: Bool { dragRect != nil }
}

/// The screen the picker appears on (SPEC 4.6 の 1: マウスのある画面で出す).
@MainActor
enum OverlayPickerPlacement {
    static func screenForMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

/// Finds the window under the cursor (SPEC 4.6 の 1).
enum OverlayWindowFinder {
    /// The frontmost ordinary window containing `point`, in global CoreGraphics
    /// coordinates (top-left origin). Our own windows and the desktop are left
    /// out, as are the tiny helper windows that would make a useless selection.
    static func window(under point: CGPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid == ownPID { continue }
            guard let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.05 else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
            else { continue }
            guard width >= 40, height >= 40 else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if rect.contains(point) { return rect }
        }
        return nil
    }
}
