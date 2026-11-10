import AppKit
import SwiftUI
import YakuCore

/// The 「押して登録する欄」 of the shortcut settings (SPEC 4.4). Built here
/// rather than pulled in, because the app takes no external dependencies.
struct ShortcutRecorder: NSViewRepresentable {
    var accessibleName = "ショートカット"
    var shortcut: Shortcut?
    /// True when this shortcut overlaps another one (SPEC 4.4: 重なったら警告).
    var conflicted: Bool
    /// True when the system refused to register it (another app holds the key).
    var registrationFailed: Bool = false
    var onChange: (Shortcut) -> Void
    var onClear: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.onClear = onClear
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.focusRingType = .exterior
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.conflicted = conflicted
        view.registrationFailed = registrationFailed
        view.onChange = onChange
        view.onClear = onClear
        view.setAccessibilityLabel(accessibleName)
        view.setAccessibilityValue(shortcut?.display ?? "なし")
        view.setAccessibilityHelp("Return またはスペースで登録を開始、Esc でやめる")
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut? { didSet { needsDisplay = true } }
        var conflicted = false { didSet { needsDisplay = true } }
        var registrationFailed = false { didSet { needsDisplay = true } }
        var onChange: ((Shortcut) -> Void)?
        var onClear: (() -> Void)?

        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        override func accessibilityPerformPress() -> Bool {
            window?.makeFirstResponder(self)
            isRecording = true
            return true
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 22) }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            let warned = conflicted || registrationFailed
            let strokeColor: NSColor = warned ? .systemRed
                : (isRecording ? .controlAccentColor : .separatorColor)
            strokeColor.setStroke()
            path.lineWidth = warned || isRecording ? 1.5 : 1
            path.stroke()

            let text: String
            if isRecording {
                text = "キーを押す…"
            } else if let shortcut {
                text = shortcut.display
            } else {
                text = "なし"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: shortcut == nil && !isRecording
                    ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                isRecording = false
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(nil) }
                else { window?.selectNextKeyView(nil) }
                return
            }
            if !isRecording, event.keyCode == 36 || event.keyCode == 49 {
                isRecording = true
                return
            }
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 53: // esc: stop recording without changing anything
                isRecording = false
                return
            case 51, 117: // delete: clear the shortcut
                isRecording = false
                onClear?()
                return
            default:
                break
            }

            let modifiers = ShortcutModifiers(event.modifierFlags)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return
            }
            let shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
            self.shortcut = shortcut
            isRecording = false
            onChange?(shortcut)
        }
    }
}

/// One row of the shortcut settings: a name, the recorder and a reset button.
struct ShortcutRow: View {
    let title: String
    let help: String
    @Bindable var settings: AppSettings
    let bindingID: String
    let conflicted: Bool
    /// The system refused this shortcut (another app already uses the key).
    var registrationFailed: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if registrationFailed {
                    Text("他のアプリが使っています")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else {
                    Text(help)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ShortcutRecorder(
                accessibleName: "\(title)のショートカット",
                shortcut: current,
                conflicted: conflicted,
                registrationFailed: registrationFailed,
                onChange: { set($0) },
                onClear: { set(nil) }
            )
            .frame(width: 130, height: 22)
            Button {
                set(defaultShortcut)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("既定に戻す")
            .accessibilityLabel("\(title)のショートカットを既定に戻す")
        }
    }

    private var current: Shortcut? {
        switch bindingID {
        case ShortcutDefaults.panelID: settings.panelShortcut
        case ShortcutDefaults.screenID: settings.screenShortcut
        default: settings.selectionShortcut
        }
    }

    private var defaultShortcut: Shortcut {
        switch bindingID {
        case ShortcutDefaults.panelID: ShortcutDefaults.panel
        case ShortcutDefaults.screenID: ShortcutDefaults.screen
        default: ShortcutDefaults.selection
        }
    }

    private func set(_ shortcut: Shortcut?) {
        // A cleared field falls back to the default; the settings store keeps
        // the value, so the recorder only ever shows a usable shortcut.
        let value = shortcut ?? defaultShortcut
        switch bindingID {
        case ShortcutDefaults.panelID: settings.panelShortcut = value
        case ShortcutDefaults.screenID: settings.screenShortcut = value
        default: settings.selectionShortcut = value
        }
        NotificationCenter.default.post(name: .yakuShortcutsChanged, object: nil)
    }
}

extension Notification.Name {
    static let yakuShortcutsChanged = Notification.Name("dev.naoya.yaku.shortcutsChanged")
}
