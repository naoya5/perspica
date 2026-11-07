import AppKit
import CoreGraphics

/// The three coordinate systems the overlay touches, and the conversions
/// between them.
///
///   - **AppKit**: origin at the bottom left of the primary display, y up.
///     `NSScreen.frame` and window frames use this.
///   - **CoreGraphics**: origin at the top left of the primary display, y down.
///     `CGWindowListCopyWindowInfo` and ScreenCaptureKit use this.
///   - **capture pixels**: origin at the top left of the captured region.
enum ScreenGeometry {
    /// The height of the primary display, which is the pivot for the two
    /// global systems.
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    /// The conversion is its own inverse: both systems have the same width and
    /// the same x, and the y is mirrored about the primary display.
    static func appKitRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A screen's frame in CoreGraphics coordinates.
    static func cgRect(for screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    static func screen(containingCGRect rect: CGRect) -> NSScreen? {
        let appKit = appKitRect(fromCG: rect)
        return NSScreen.screens.first { $0.frame.intersects(appKit) }
    }

    static func screen(containingCGPoint point: CGPoint) -> NSScreen? {
        screen(containingCGRect: CGRect(x: point.x, y: point.y, width: 1, height: 1))
    }

    /// The display id `NSScreen` is showing on, which is how a screen is matched
    /// to an `SCDisplay`.
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Where a block from the captured image sits in the overlay window, whose
    /// frame is the whole screen.
    ///
    /// `capture` is the captured region in CoreGraphics points; `pixelRect` is
    /// the block inside the image, with the origin at its top left.
    static func windowRect(
        forPixelRect pixelRect: CGRect,
        capture: CGRect,
        scale: CGFloat,
        screen: NSScreen
    ) -> CGRect {
        let appKitCapture = appKitRect(fromCG: capture)
        let x = appKitCapture.minX - screen.frame.minX + pixelRect.minX / scale
        let bottom = appKitCapture.minY - screen.frame.minY
        let heightPoints = appKitCapture.height - pixelRect.maxY / scale
        return CGRect(
            x: x,
            y: bottom + heightPoints,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale
        )
    }
}
