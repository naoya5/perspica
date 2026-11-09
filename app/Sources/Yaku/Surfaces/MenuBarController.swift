import AppKit

/// The menu bar icon: left click toggles the panel, right click opens the menu.
@MainActor
final class MenuBarController: NSObject {
    /// What the icon shows about the PDF queue (SPEC 4.1).
    enum PDFBadge: Equatable {
        case none
        case progress(Double)
        case finished
        case failed
    }

    var onToggle: (() -> Void)?
    var onPause: (() -> Void)?
    var onOpenManager: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private var blinkTimer: Timer?
    private var badge: MenuBarBadgeView?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    /// Frame of the menu bar item, in screen coordinates. Used to put the panel
    /// directly under the icon.
    var buttonFrame: NSRect? {
        statusItem.button?.window?.frame
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Perspica")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Perspica（⌃⌥K でパネル）"

        let badge = MenuBarBadgeView(frame: button.bounds)
        badge.autoresizingMask = [.width, .height]
        button.addSubview(badge)
        self.badge = badge
    }

    /// The PDF progress ring, the one-off bounce, and the failure dot.
    func setPDFBadge(_ value: PDFBadge) {
        badge?.mode = value
        if case .finished = value {
            badge?.bounce()
        }
    }

    /// Slow blink while the engine is loading (SPEC 4.1).
    func setEngineBusy(_ busy: Bool) {
        if busy {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                button.alphaValue = button.alphaValue > 0.7 ? 0.4 : 1.0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        statusItem.button?.alphaValue = 1
    }

    @objc private func buttonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showMenu()
        } else {
            onToggle?()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let managerItem = NSMenuItem(title: "管理画面を開く", action: #selector(openManager), keyEquivalent: "")
        managerItem.target = self
        menu.addItem(managerItem)

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: "一時停止", action: #selector(pause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    @objc private func openManager() {
        onOpenManager?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func pause() {
        onPause?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

/// Draws the PDF state over the menu bar icon (SPEC 4.1): a 7pt progress ring
/// at the bottom right, a green checkmark that bounces once when a job
/// finishes, and a 5pt red dot when one fails.
///
/// It is a subview of the status button so the icon itself stays a template
/// image and keeps adapting to a light or dark menu bar.
@MainActor
final class MenuBarBadgeView: NSView {
    var mode: MenuBarController.PDFBadge = .none {
        didSet {
            needsDisplay = true
            if case .none = mode { layer?.removeAllAnimations() }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { false }

    func bounce() {
        wantsLayer = true
        guard let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.35, 0.95, 1.0]
        animation.keyTimes = [0, 0.35, 0.7, 1]
        animation.duration = 0.42
        layer.add(animation, forKey: "bounce")
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .none:
            break

        case .progress(let value):
            let ring = NSRect(x: bounds.maxX - 9.5, y: 1, width: 7, height: 7)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()

            let center = NSPoint(x: ring.midX, y: ring.midY)
            let radius = (ring.width - 1.5) / 2
            let clamped = min(max(value, 0.02), 1)
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(clamped),
                clockwise: true
            )
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            arc.stroke()

        case .finished:
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            let rect = NSRect(x: bounds.maxX - 10.5, y: 0.5, width: 9, height: 9)
            symbol?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

        case .failed:
            let dot = NSRect(x: bounds.maxX - 8, y: 1.5, width: 5, height: 5)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
