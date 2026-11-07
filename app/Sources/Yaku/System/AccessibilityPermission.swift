import AppKit
import ApplicationServices

/// The accessibility permission the selection features need (SPEC 10).
enum AccessibilityPermission {
    private static let promptedKey = "accessibilityPromptShown"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its permission prompt, at most once per install
    /// (SPEC 10: 何度も聞き直さない). Granting is always the user's action; the
    /// app never changes the setting itself.
    @discardableResult
    static func promptOnce() -> Bool {
        guard !UserDefaults.standard.bool(forKey: promptedKey) else {
            return isTrusted
        }
        UserDefaults.standard.set(true, forKey: promptedKey)
        // `kAXTrustedCheckOptionPrompt` is an imported mutable global, which
        // Swift 6 will not read directly; the string is its documented value.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppLog.write("accessibility prompt shown; trusted=\(trusted)")
        return trusted
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        AppLog.write("opening accessibility settings")
        NSWorkspace.shared.open(url)
    }
}
