import AppKit
import ApplicationServices

/// Everything the HUD needs about the text the user selected (SPEC 4.3, 5.2).
@MainActor
struct SelectionCapture {
    let text: String
    /// The element the selection belongs to. Kept so ⌘↩ can write back even
    /// after our own panel becomes key.
    let element: AXUIElement
    let appPID: pid_t
    /// The selection's rectangle in accessibility coordinates (origin at the
    /// top left of the main display, y growing downward), when the app reports
    /// one.
    let bounds: CGRect?
    let canReplace: Bool
    let frontApp: String
    let windowTitle: String
    /// F1 context: the front app, the window title and 200 characters on each
    /// side of the selection (SPEC 5.2).
    let context: String?
}

/// Reads the selection from the frontmost app: first through the accessibility
/// API, then with a synthetic ⌘C and a clipboard restore (SPEC 10).
@MainActor
enum SelectionReader {
    static let contextRadius = 200

    /// Returns nil when the app cannot read a selection. A missing permission
    /// is checked by the caller first so it can show the right message.
    static func capture() -> SelectionCapture? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let focused = focusedElement() else { return nil }
        guard !isSecure(focused) else {
            AppLog.write("selection: focused element is a secure field; refusing")
            return nil
        }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = focusedWindowTitle(for: focused)

        if let text = selectedText(of: focused), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (bounds, boundsSource) = selectionAnchor(of: focused)
            let context = contextText(of: focused, frontApp: frontApp, windowTitle: windowTitle)
            AppLog.write("selection: accessibility read \(text.count) chars "
                + "bounds=\(String(describing: bounds)) from=\(boundsSource)")
            return SelectionCapture(
                text: text,
                element: focused,
                appPID: pid(of: focused),
                bounds: bounds,
                canReplace: isSettable(focused),
                frontApp: frontApp,
                windowTitle: windowTitle,
                context: context
            )
        }

        // SPEC 10: fall back to ⌘C, wait at most 150ms for the pasteboard to
        // change, then put the old contents back.
        if let text = copyFallback(from: focused) {
            let context = contextText(of: focused, frontApp: frontApp, windowTitle: windowTitle)
            AppLog.write("selection: ⌘C fallback read \(text.count) chars")
            return SelectionCapture(
                text: text,
                element: focused,
                appPID: pid(of: focused),
                bounds: mouseLocationInAXCoordinates(),
                canReplace: isSettable(focused),
                frontApp: frontApp,
                windowTitle: windowTitle,
                context: context
            )
        }

        AppLog.write("selection: nothing selected")
        return nil
    }

    /// Writes `text` over the selection (SPEC 10). Accessibility first; when
    /// the element refuses, the translation goes through the pasteboard and a
    /// synthetic ⌘V, and the old clipboard contents are restored.
    static func replace(_ capture: SelectionCapture, with text: String) -> Bool {
        guard isCurrentTarget(capture.element, appPID: capture.appPID) else { return false }
        let result = AXUIElementSetAttributeValue(
            capture.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if result == .success {
            AppLog.write("replace: wrote \(text.count) chars with kAXSelectedTextAttribute")
            return true
        }
        AppLog.write("replace: kAXSelectedTextAttribute failed (\(result)); trying ⌘V")
        return pasteFallback(text, into: capture)
    }

    /// Never send a command or write into a stale capture after focus changed.
    private static func isCurrentTarget(_ element: AXUIElement, appPID: pid_t) -> Bool {
        guard AccessibilityPermission.isTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == appPID,
              let focused = focusedElement(),
              CFEqual(focused, element),
              pid(of: focused) == appPID,
              !isSecure(focused) else { return false }
        return true
    }

    // MARK: accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private static func selectedBounds(of element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(of: element) else { return nil }
        var mutableRange = range
        guard let rangeValue = withUnsafePointer(to: &mutableRange, { AXValueCreate(.cfRange, $0) }) else {
            return nil
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect.isEmpty ? nil : rect
    }

    /// Where the HUD goes (SPEC 4.3): the selection's own rectangle when the
    /// app reports one. Safari and other WebKit views answer the text-marker
    /// attributes instead of `kAXBoundsForRange`; when neither works the mouse
    /// is used, which has just made the selection in most cases.
    private static func selectionAnchor(of element: AXUIElement) -> (CGRect?, String) {
        if let rect = usable(selectedBounds(of: element)) { return (rect, "range") }
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if let rect = usable(textMarkerBounds(of: candidate)) { return (rect, "text-marker") }
            current = parent(of: candidate)
        }
        return (mouseLocationInAXCoordinates(), "mouse")
    }

    /// A selection taller than most of the screen (select all on a long page)
    /// says nothing about where the reader is looking.
    private static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width >= 1, rect.height >= 1 else { return nil }
        let screenHeight = NSScreen.screens.map(\.frame.height).max() ?? 0
        return rect.height > screenHeight * 0.6 ? nil : rect
    }

    private static func textMarkerBounds(of element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            range,
            &value
        )
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect.isEmpty ? nil : rect
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    /// SPEC 5.3: password fields are never read. AppKit reports them by
    /// role; web views and many other apps report a text field whose
    /// subrole is `AXSecureTextField`, so both are checked.
    /// The focused element can be a piece inside the field (a web view's
    /// inner editor), so a few ancestors are checked too.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let candidate = current else { return false }
            if stringAttribute(kAXRoleAttribute, of: candidate) == secure
                || stringAttribute(kAXSubroleAttribute, of: candidate) == secure {
                return true
            }
            current = parent(of: candidate)
        }
        return false
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private static func focusedWindowTitle(for element: AXUIElement) -> String {
        let application = AXUIElementCreateApplication(pid(of: element))
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return ""
        }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue((window as! AXUIElement), kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else {
            return ""
        }
        return text
    }

    /// The front app, the window title and 200 characters either side of the
    /// selection, when the element exposes its whole text.
    private static func contextText(of element: AXUIElement, frontApp: String, windowTitle: String) -> String? {
        var parts: [String] = []
        if !frontApp.isEmpty { parts.append(frontApp) }
        if !windowTitle.isEmpty { parts.append(windowTitle) }

        if let range = selectedRange(of: element), let full = valueText(of: element) {
            let text = full as NSString
            let location = max(0, min(range.location, text.length))
            let length = max(0, min(range.length, text.length - location))
            let beforeStart = max(0, location - contextRadius)
            let before = text.substring(with: NSRange(location: beforeStart, length: location - beforeStart))
            let afterStart = min(text.length, location + length)
            let afterLength = min(contextRadius, text.length - afterStart)
            let after = text.substring(with: NSRange(location: afterStart, length: afterLength))
            if !before.isEmpty { parts.append(before) }
            if !after.isEmpty { parts.append(after) }
        }

        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func valueText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    // MARK: clipboard fallbacks

    private static func copyFallback(from element: AXUIElement) -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        guard isCurrentTarget(element, appPID: pid(of: element)),
              sendCommand(keyCode: 0x08) else { return nil } // C

        var changed = false
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                changed = true
                break
            }
            usleep(8_000)
        }

        var text: String?
        if changed {
            text = pasteboard.string(forType: .string)
        }
        restore(pasteboard, items: saved)

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Pastes through the pasteboard. A posted ⌘V is not proof that the app
    /// pasted, so success is reported only when the field visibly changed:
    /// its value or its selection range. A field that exposes neither cannot
    /// be confirmed and is reported as not replaced (the HUD stays open).
    private static func pasteFallback(_ text: String, into capture: SelectionCapture) -> Bool {
        let element = capture.element
        guard isCurrentTarget(element, appPID: capture.appPID) else { return false }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = valueText(of: element)
        let rangeBefore = selectedRange(of: element)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(pasteboard, items: saved)
            AppLog.write("replace: could not put the translation on the pasteboard")
            return false
        }

        guard isCurrentTarget(element, appPID: capture.appPID),
              sendCommand(keyCode: 0x09) else { // V
            restore(pasteboard, items: saved)
            AppLog.write("replace: could not post ⌘V")
            return false
        }
        // Give the target app a moment to read the pasteboard before the old
        // contents go back.
        usleep(120_000)
        let after = valueText(of: element)
        let rangeAfter = selectedRange(of: element)
        restore(pasteboard, items: saved)

        var changed: Bool?
        if let before, let after { changed = before != after }
        if changed != true, let rangeBefore, let rangeAfter {
            changed = rangeBefore.location != rangeAfter.location || rangeBefore.length != rangeAfter.length
        }
        guard let changed else {
            AppLog.write("replace: ⌘V sent but the field exposes nothing to confirm it; not reported as replaced")
            return false
        }
        AppLog.write("replace: ⌘V \(changed ? "changed" : "did not change") the field")
        return changed
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Posts ⌘ + key. False when the events could not be made, so nothing
    /// was sent.
    @discardableResult
    private static func sendCommand(keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The mouse position converted into the same coordinate space as
    /// accessibility bounds, for when the selection has no rectangle.
    private static func mouseLocationInAXCoordinates() -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        let y = screen.frame.maxY - mouse.y
        return CGRect(x: mouse.x, y: y, width: 1, height: 1)
    }
}
