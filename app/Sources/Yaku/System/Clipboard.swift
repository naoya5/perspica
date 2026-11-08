import AppKit

/// The one way Yaku puts text on the clipboard. The panel, the HUD, the
/// manager and the overlay all copy plain text the same way.
enum Clipboard {
    /// Replaces the clipboard with `text`. Returns false, and leaves the
    /// clipboard alone, when there is nothing to copy.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }
}
