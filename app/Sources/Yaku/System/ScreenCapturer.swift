import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

/// One screenshot through ScreenCaptureKit (SPEC 9).
///
/// The image is kept at the display's own scale, so Retina text stays sharp
/// enough for Vision, and the app's own windows are left out of the filter so
/// the overlay cannot photograph itself.
@MainActor
enum ScreenCapturer {
    struct Capture {
        let image: CGImage
        /// The captured region in global CoreGraphics points (top-left origin).
        let rect: CGRect
        /// The display's backing scale, so image pixels = points × scale.
        let scale: CGFloat
        let screen: NSScreen
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case tooSmall
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: "画面が見つかりませんでした"
            case .tooSmall: "選んだ範囲が小さすぎます"
            case .failed(let message): message
            }
        }
    }

    /// Captures `rect` (global CoreGraphics points). The rectangle is clamped to
    /// the display it lands on, because a window can stick out over an edge.
    static func capture(rect: CGRect) async throws -> Capture {
        guard let screen = ScreenGeometry.screen(containingCGRect: rect) ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        let scale = screen.backingScaleFactor
        let clamped = rect.intersection(ScreenGeometry.cgRect(for: screen))
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else {
            throw CaptureError.tooSmall
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed("\(error)")
        }

        let wanted = ScreenGeometry.displayID(for: screen)
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { window in
            guard let ownBundle else { return false }
            return window.owningApplication?.bundleIdentifier == ownBundle
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let displayBounds = CGDisplayBounds(display.displayID)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: clamped.minX - displayBounds.minX,
            y: clamped.minY - displayBounds.minY,
            width: clamped.width,
            height: clamped.height
        )
        configuration.width = max(1, Int((clamped.width * scale).rounded()))
        configuration.height = max(1, Int((clamped.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            AppLog.write("overlay: captured \(Int(clamped.width))x\(Int(clamped.height))pt "
                + "→ \(image.width)x\(image.height)px scale=\(scale) display=\(display.displayID)")
            return Capture(image: image, rect: clamped, scale: scale, screen: screen)
        } catch {
            throw CaptureError.failed("\(error)")
        }
    }

    /// Loads a PNG from disk for `--demo-image` (SPEC 15), so the overlay can be
    /// checked without the screen recording permission.
    static func loadImage(at path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }
}
