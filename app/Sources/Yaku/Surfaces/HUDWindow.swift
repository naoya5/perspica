import AppKit
import Observation
import SwiftUI
import YakuCore

/// The HUD's window: same construction as the panel (SPEC 4.3), so the
/// frontmost app stays frontmost and only the HUD takes key input.
final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Passes clicks through everywhere outside the glass shape.
@MainActor
final class HUDContainerView: NSView {
    private let model: HUDModel
    private let hosting: NSHostingView<HUDView>
    private let glow: GlowPresenter

    init(model: HUDModel, coordinator: TranslationCoordinator, actions: HUDActions) {
        self.model = model
        self.hosting = NSHostingView(
            rootView: HUDView(model: model, coordinator: coordinator, actions: actions)
        )
        self.glow = GlowPresenter(
            cornerRadius: HUDLayout.cornerRadius,
            shapeRect: {
                HUDLayout.shapeRect(
                    in: CGRect(origin: .zero, size: HUDLayout.windowSize),
                    height: model.contentHeight,
                    flipped: false
                )
            },
            phase: { coordinator.hud.phase },
            isOpen: { model.isVisible }
        )
        super.init(frame: CGRect(origin: .zero, size: HUDLayout.windowSize))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        glow.view.frame = shapeRect()
        addSubview(glow.view, positioned: .above, relativeTo: hosting)
        glow.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HUDContainerView does not support NSCoder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return shapeRect().contains(local) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        glow.view.frame = shapeRect()
    }

    private func shapeRect() -> CGRect {
        HUDLayout.shapeRect(in: bounds, height: model.contentHeight, flipped: isFlipped)
    }
}

/// Owns the HUD window: showing it near the selection, hiding it again, and
/// the actions its buttons and keys perform.
@MainActor
final class HUDController {
    let model = HUDModel()
    private(set) var capture: SelectionCapture?

    /// Called when the HUD asks for the panel to open.
    var onOpenPanel: (() -> Void)?

    private let coordinator: TranslationCoordinator
    private var window: HUDWindow?
    private var anchor: CGRect?
    private var noticeTask: Task<Void, Never>?

    init(coordinator: TranslationCoordinator) {
        self.coordinator = coordinator
    }

    var isVisible: Bool { model.isVisible }

    /// True while the HUD is the window taking key input.
    var isKeyWindow: Bool { model.isVisible && window?.isKeyWindow == true }

    // MARK: showing

    func show(capture: SelectionCapture, anchor: CGRect?) {
        noticeTask?.cancel()
        noticeTask = nil
        self.capture = capture
        self.anchor = anchor ?? capture.bounds ?? mouseAnchor()
        model.notice = nil
        model.canReplace = capture.canReplace
        present()
        AppLog.write("hud show anchor=\(String(describing: self.anchor)) canReplace=\(capture.canReplace)")
        coordinator.translateHUD(text: capture.text, context: capture.context, frontApp: capture.frontApp)
    }

    /// `--demo-surface hud --demo-text`: show the HUD for a given string
    /// without going through selection capture.
    func showDemoText(_ text: String, anchor: CGRect?) {
        noticeTask?.cancel()
        noticeTask = nil
        capture = nil
        model.canReplace = false
        model.notice = nil
        self.anchor = anchor ?? mouseAnchor()
        present()
        AppLog.write("hud demo text anchor=\(String(describing: self.anchor))")
        coordinator.translateHUD(text: text, context: nil, frontApp: nil)
    }

    func showNoSelection() {
        showNotice(.noSelection, autoHideAfter: 1.5)
    }

    func showPermissionNeeded() {
        showNotice(.permissionNeeded, autoHideAfter: nil)
    }

    private func showNotice(_ notice: HUDNotice, autoHideAfter: TimeInterval?) {
        noticeTask?.cancel()
        noticeTask = nil
        coordinator.dismissHUD()
        capture = nil
        model.canReplace = false
        model.notice = notice
        anchor = mouseAnchor()
        present()
        AppLog.write("hud notice \(notice)")
        if let autoHideAfter {
            noticeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoHideAfter * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hide(reason: "no-selection timeout")
            }
        }
    }

    func hide(reason: String) {
        noticeTask?.cancel()
        noticeTask = nil
        guard model.isVisible else { return }
        model.isVisible = false
        window?.ignoresMouseEvents = true
        window?.resignKey()
        capture = nil
        coordinator.dismissHUD()
        AppLog.write("hud hide (\(reason))")
    }

    // MARK: actions

    func copy() {
        let text = coordinator.hud.translation
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.write("hud copy \(text.count) chars")
    }

    func replaceSelection() {
        guard let capture else { return }
        let text = coordinator.hud.translation
        guard !text.isEmpty else { return }
        if SelectionReader.replace(capture, with: text) {
            hide(reason: "replaced")
        }
    }

    func openInPanel() {
        let source = coordinator.hud.sourceText
        guard !source.isEmpty else { return }
        coordinator.openInPanel(source: source)
        hide(reason: "opened in panel")
        onOpenPanel?()
    }

    func toggleSourceDisplay() {
        // The view reads `coordinator.optionDown`; nothing to do here.
    }

    // MARK: window

    private func present() {
        let window = makeWindowIfNeeded()
        position()
        model.isVisible = true
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindowIfNeeded() -> HUDWindow {
        if let window { return window }

        let actions = HUDActions(
            replace: { [weak self] in self?.replaceSelection() },
            openInPanel: { [weak self] in self?.openInPanel() }
        )
        let hosting = HUDContainerView(model: model, coordinator: coordinator, actions: actions)
        hosting.frame = CGRect(origin: .zero, size: HUDLayout.windowSize)

        let window = HUDWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderFrontRegardless()

        self.window = window
        observeHeight()
        return window
    }

    /// The shape grows downward from the anchor, so the window is only moved
    /// again when the content grows past the bottom of the screen.
    private func observeHeight() {
        withObservationTracking { [model] in
            _ = model.contentHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.position()
                self.observeHeight()
            }
        }
    }

    private func position() {
        guard let window, let anchor else { return }
        let height = model.contentHeight
        let screen = screen(containing: anchor) ?? NSScreen.main ?? NSScreen.screens[0]
        let shapeTop = shapeTop(anchor: anchor, height: height, screen: screen)
        let wantedX = anchor.midX - HUDLayout.width / 2
        let shapeX = min(
            max(wantedX, screen.frame.minX + HUDLayout.screenEdgeInset),
            screen.frame.maxX - HUDLayout.screenEdgeInset - HUDLayout.width
        )
        let origin = CGPoint(
            x: shapeX - HUDLayout.shadowMargin,
            y: shapeTop - HUDLayout.windowHeight
        )
        window.setFrame(CGRect(origin: origin, size: HUDLayout.windowSize), display: true)
        AppLog.write(String(
            format: "hud position anchor=%@ height=%.0f shapeTop=%.0f x=%.0f",
            String(describing: anchor), height, shapeTop, shapeX
        ))
    }

    /// SPEC 4.3: below the selection, or above it when there is no room.
    private func shapeTop(anchor: CGRect, height: CGFloat, screen: NSScreen) -> CGFloat {
        let primary = primaryScreenHeight()
        let selectionBottom = primary - anchor.maxY
        let below = selectionBottom - HUDLayout.gap
        let minimum = screen.frame.minY + HUDLayout.screenEdgeInset
        if below - height >= minimum { return below }

        let selectionTop = primary - anchor.minY
        let above = selectionTop + HUDLayout.gap
        return min(above, screen.frame.maxY - height - HUDLayout.screenEdgeInset)
    }

    private func screen(containing anchor: CGRect) -> NSScreen? {
        let primary = primaryScreenHeight()
        let rect = CGRect(
            x: anchor.minX,
            y: primary - anchor.maxY,
            width: max(anchor.width, 1),
            height: max(anchor.height, 1)
        )
        return NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private func primaryScreenHeight() -> CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return primary?.frame.height ?? 0
    }

    private func mouseAnchor() -> CGRect {
        let primary = primaryScreenHeight()
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: primary - mouse.y, width: 1, height: 1)
    }
}
