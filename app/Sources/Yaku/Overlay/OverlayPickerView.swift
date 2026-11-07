import AppKit
import SwiftUI

/// Full-screen, borderless panel for the region picker (SPEC 4.6 の 1). It is
/// the key window so Space and Esc arrive, but it never activates the app.
final class OverlayPickerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The picker's own view: the dimming scrim, the outline and the glass capsule.
struct OverlayPickerView: View {
    @Bindable var model: OverlayPickerModel
    var onSelectMode: (OverlayPickMode) -> Void

    @Namespace private var modeNamespace

    var body: some View {
        ZStack(alignment: .top) {
            // SPEC 4.6 の 1: 薄い暗幕（黒 15%）.
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            outline
            capsule
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height, alignment: .top)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            // The capsule's rect, in the window's AppKit coordinates, so the
            // controller can let its clicks through.
            model.capsuleRect = CGRect(
                x: frame.midX - capsuleSize.width / 2,
                y: model.screenSize.height - capsuleTop - capsuleSize.height,
                width: capsuleSize.width,
                height: capsuleSize.height
            )
        }
    }

    private let capsuleSize = CGSize(width: 264, height: 32)
    private let capsuleTop: CGFloat = 60

    /// The white 1pt outline around the window under the cursor, or the region
    /// being dragged (SPEC 4.6 の 1).
    @ViewBuilder
    private var outline: some View {
        if let rect = model.outlineRect, rect.width > 1, rect.height > 1 {
            let swiftY = model.screenSize.height - rect.maxY
            RoundedRectangle(cornerRadius: model.isDragging ? 4 : 2, style: .continuous)
                .fill(Color.white.opacity(model.isDragging ? 0.08 : 0.001))
                .overlay(
                    RoundedRectangle(cornerRadius: model.isDragging ? 4 : 2, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 1)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: swiftY + rect.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// `ウィンドウ｜範囲｜画面全体`, a single glass capsule (SPEC 4.6 の 1).
    private var capsule: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(OverlayPickMode.allCases) { mode in
                    segment(mode)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(width: capsuleSize.width, height: capsuleSize.height)
        .padding(.top, capsuleTop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("選ぶ範囲")
    }

    private func segment(_ mode: OverlayPickMode) -> some View {
        let selected = model.mode == mode
        return Button {
            withAnimation(.snappy(duration: 0.25)) { onSelectMode(mode) }
        } label: {
            Text(mode.title)
                .font(.system(size: 12))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(mode.rawValue, in: modeNamespace)
        .help("\(mode.title)を選ぶ")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Owns the picker window and turns mouse and key input into a selection
/// (SPEC 4.6 の 1).
@MainActor
final class OverlayPickerController {
    let model = OverlayPickerModel()

    /// Called with the chosen region in global CoreGraphics points.
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var window: OverlayPickerWindow?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var dragOrigin: CGPoint?

    var isVisible: Bool { model.screenSize != .zero && window?.isVisible == true }

    // MARK: showing

    func show(on screen: NSScreen? = nil) {
        hide()
        guard let screen = screen ?? OverlayPickerPlacement.screenForMouse() else { return }
        self.screen = screen
        model.mode = .window
        model.dragRect = nil
        model.screenSize = screen.frame.size
        model.cursor = windowPoint(NSEvent.mouseLocation)
        model.windowRect = findWindow(under: NSEvent.mouseLocation)

        let hosting = NSHostingView(rootView: OverlayPickerView(model: model, onSelectMode: { [weak self] mode in
            guard let self else { return }
            self.model.mode = mode
            if mode == .region {
                // A region needs a drag; nothing is selected yet.
                self.model.dragRect = nil
            }
        }))
        hosting.frame = CGRect(origin: .zero, size: screen.frame.size)

        let window = OverlayPickerWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
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
        window.ignoresMouseEvents = false
        window.contentView = hosting
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        self.window = window
        setUpMonitors()
        NSCursor.crosshair.push()
        AppLog.write("overlay picker: shown on \(screen.localizedName) \(screen.frame)")
    }

    func hide() {
        guard window != nil || !monitors.isEmpty else { return }
        NSCursor.pop()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        window?.orderOut(nil)
        window = nil
        dragOrigin = nil
        model.dragRect = nil
        model.screenSize = .zero
    }

    // MARK: input

    private func setUpMonitors() {
        let moved = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged],
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
                return event
            }
        )
        if let moved { monitors.append(moved) }

        let clicks = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp],
            handler: { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleClick(event) ?? false }
                return consumed ? nil : event
            }
        )
        if let clicks { monitors.append(clicks) }

        let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return consumed ? nil : event
            }
        )
        if let keys { monitors.append(keys) }
    }

    private func handleMouse(_ event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        model.cursor = point

        if event.type == .leftMouseDragged, let origin = dragOrigin {
            model.dragRect = rect(from: origin, to: point)
            return
        }
        if model.mode == .window {
            model.windowRect = findWindow(under: NSEvent.mouseLocation)
        }
    }

    /// Returns true when the picker took the click.
    private func handleClick(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)

        // A click on the glass capsule belongs to its buttons.
        if model.capsuleRect.insetBy(dx: -6, dy: -6).contains(point) { return false }

        switch event.type {
        case .leftMouseDown:
            dragOrigin = point
            model.dragRect = nil
            return true
        case .leftMouseUp:
            let origin = dragOrigin
            dragOrigin = nil
            if let origin {
                let dragged = rect(from: origin, to: point)
                if dragged.width >= 8, dragged.height >= 8 {
                    model.dragRect = dragged
                    commit(dragged)
                    return true
                }
            }
            // A plain click selects whatever the current mode points at.
            model.dragRect = nil
            if let target = model.activeRect, target.width >= 2, target.height >= 2 {
                commit(target)
            }
            return true
        default:
            return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            AppLog.write("overlay picker: cancelled with esc")
            cancel()
            return true
        case 49: // space
            let whole = CGRect(origin: .zero, size: model.screenSize)
            AppLog.write("overlay picker: whole screen with space")
            commit(whole)
            return true
        default:
            break
        }
        // 1/2/3 pick a mode, so the capsule is reachable from the keyboard too.
        switch event.charactersIgnoringModifiers {
        case "1": model.mode = .window; model.dragRect = nil; return true
        case "2": model.mode = .region; return true
        case "3": model.mode = .fullScreen; return true
        default: return false
        }
    }

    // MARK: geometry

    private func rect(from origin: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
    }

    private func windowPoint(_ appKitGlobal: CGPoint) -> CGPoint {
        guard let screen else { return appKitGlobal }
        return CGPoint(x: appKitGlobal.x - screen.frame.minX, y: appKitGlobal.y - screen.frame.minY)
    }

    /// The window under a global AppKit point, in the picker's own coordinates.
    private func findWindow(under appKitGlobal: CGPoint) -> CGRect? {
        let cgPoint = CGPoint(x: appKitGlobal.x, y: ScreenGeometry.primaryHeight - appKitGlobal.y)
        guard let cgRect = OverlayWindowFinder.window(under: cgPoint) else { return nil }
        let appKit = ScreenGeometry.appKitRect(fromCG: cgRect)
        return CGRect(
            x: appKit.minX - (screen?.frame.minX ?? 0),
            y: appKit.minY - (screen?.frame.minY ?? 0),
            width: appKit.width,
            height: appKit.height
        )
    }

    /// Turns a picker-local rect into a global CoreGraphics rect and hands it
    /// over.
    private func commit(_ local: CGRect) {
        guard let screen else { return }
        let appKitGlobal = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let cg = ScreenGeometry.cgRect(fromAppKit: appKitGlobal)
        AppLog.write("overlay picker: selected \(cg)")
        let callback = onSelect
        hide()
        callback?(cg)
    }

    private func cancel() {
        let callback = onCancel
        hide()
        callback?()
    }
}
