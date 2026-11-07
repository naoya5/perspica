import AppKit
import SwiftUI
import YakuCore

/// The 「押して登録する欄」 of the shortcut settings (SPEC 4.4). Built here
/// rather than pulled in, because the app takes no external dependencies.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut?
    /// True when this shortcut overlaps another one (SPEC 4.4: 重なったら警告).
    var conflicted: Bool
    var onChange: (Shortcut) -> Void
    var onClear: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.onClear = onClear
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.conflicted = conflicted
        view.onChange = onChange
        view.onClear = onClear
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut? { didSet { needsDisplay = true } }
        var conflicted = false { didSet { needsDisplay = true } }
        var onChange: ((Shortcut) -> Void)?
        var onClear: (() -> Void)?

        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 22) }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            let strokeColor: NSColor = conflicted ? .systemRed
                : (isRecording ? .controlAccentColor : .separatorColor)
            strokeColor.setStroke()
            path.lineWidth = conflicted || isRecording ? 1.5 : 1
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutRecorder(
                shortcut: current,
                conflicted: conflicted,
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
