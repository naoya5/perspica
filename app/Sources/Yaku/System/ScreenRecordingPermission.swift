import AppKit
import CoreGraphics

/// The screen recording permission the overlay needs (SPEC 10, 13).
///
/// It is asked for right before the first capture and never again on its own
/// (SPEC 10: 何度も聞き直さない). Granting is always the user's action; the app
/// never changes the setting itself.
enum ScreenRecordingPermission {
    private static let promptedKey = "screenRecordingPromptShown"

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system's own prompt, at most once per install. The answer is
    /// usually "not yet": macOS makes the user grant it in System Settings and
    /// then the app has to be started again.
    @discardableResult
    static func requestOnce() -> Bool {
        if isGranted { return true }
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return isGranted }
        UserDefaults.standard.set(true, forKey: promptedKey)
        let granted = CGRequestScreenCaptureAccess()
        AppLog.write("screen recording prompt shown; granted=\(granted)")
        return granted
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        AppLog.write("screen recording: opening system settings")
        NSWorkspace.shared.open(url)
    }
}
