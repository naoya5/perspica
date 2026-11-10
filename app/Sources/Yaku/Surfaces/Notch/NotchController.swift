import AppKit
import SwiftUI

/// Borderless panel that can be pushed above the menu bar (notch-app SPEC 2).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Without this, AppKit keeps the window below the menu bar, which would
    /// push the island ~32pt down from the physical screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that only claims mouse events inside the black shape, and is
/// the drop target for files dragged to the top of the screen.
final class NotchHostingView: NSHostingView<NotchRootView> {
    weak var model: NotchModel?
    var onDrop: ((URL) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return shapeRect().contains(local) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func shapeRect() -> CGRect {
        guard let model else { return .zero }
        let size = model.islandSize
        let x = (bounds.width - size.width) / 2
        let y: CGFloat = isFlipped ? 0 : bounds.height - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        model?.dragNear(isOverIsland: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        model?.dragNear(isOverIsland: true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model?.dragLeftZone()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURL(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        urls.forEach { onDrop?($0) }
        return true
    }

    private func hasFileURL(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
    }
}

/// Owns the island window: its position over the notch, the drag detection and
/// the click/Esc handling (SPEC 4.5).
@MainActor
final class NotchController {
    let model = NotchModel()

    /// Called with a file dropped on the island.
    var onDrop: ((URL) -> Void)?
    /// Called when a dropped file is not a PDF, so the caller can shake the panel too.
    var onReject: (() -> Void)?
    var onRetry: (() -> Void)?

    private var panel: NotchPanel?
    private var hosting: NotchHostingView?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var elapsedTimer: Timer?

    /// The display with a notch, if there is one.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    /// Creates the window when the setting is on and a notch exists (SPEC 4.5:
    /// ノッチのある画面で、設定がオンのときだけ使う). `force` is the demo path:
    /// it draws the island on the main display when no notch exists, so the
    /// states can still be photographed.
    func setUp(enabled: Bool, force: Bool = false) {
        guard enabled else {
            tearDown()
            AppLog.write("notch: not used (setting is off)")
            return
        }
        guard panel == nil else { return }
        guard let screen = Self.notchScreen() ?? (force ? NSScreen.main : nil) else {
            AppLog.write("notch: not used (no notch on any display)")
            return
        }
        self.screen = screen
        configureNotchSize(on: screen)

        let root = NotchRootView(
            model: model,
            onOpen: { [weak self] dual in self?.openOutput(dual: dual) },
            onReveal: { [weak self] in self?.revealOutput() },
            onShowLog: { NSWorkspace.shared.open(AppPaths.logsDirectory) },
            onRetry: { [weak self] in self?.onRetry?() }
        )
        let hosting = NotchHostingView(rootView: root)
        hosting.model = model
        hosting.registerForDraggedTypes([.fileURL])
        hosting.onDrop = { [weak self] url in self?.acceptDrop(url) }
        hosting.frame = CGRect(origin: .zero, size: Self.windowSize)

        let panel = NotchPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = hosting
        position()
        setUpMonitors()
        AppLog.write("notch: island at \(panel.frame) notch=\(model.notchSize) screen=\(screen.localizedName)")
    }

    func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    // MARK: geometry

    private static let windowSize = CGSize(width: 640, height: 520)

    private func configureNotchSize(on screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            model.notchSize = CGSize(width: max(120, width), height: max(24, screen.safeAreaInsets.top))
        }
    }

    private func position() {
        guard let panel, let screen else { return }
        let size = Self.windowSize
        panel.setFrame(
            CGRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func islandRect() -> CGRect {
        guard let screen else { return .zero }
        let size = model.islandSize
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func dropZone() -> CGRect {
        guard let screen else { return .zero }
        return CGRect(x: screen.frame.midX - 250, y: screen.frame.maxY - 80, width: 500, height: 80)
    }

    // MARK: monitors

    private func setUpMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleGlobal(event) }
                return event
            }
        ) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleGlobal(event) }
            }
        ) {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return consumed ? nil : event
            }
        ) {
            monitors.append(keys)
        }
    }

    private func handleGlobal(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            updateDrag()
        case .leftMouseUp:
            if model.state == .drop { model.dragLeftZone() }
        case .leftMouseDown:
            if model.expanded, !islandRect().contains(NSEvent.mouseLocation) {
                model.expanded = false
            }
        default:
            break
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true else { return false }
        if event.keyCode == 53 { // esc
            if model.expanded {
                model.expanded = false
            } else {
                model.close()
                panel?.resignKey()
            }
            return true
        }
        return false
    }

    private func updateDrag() {
        let point = NSEvent.mouseLocation
        guard dropZone().contains(point) else {
            if model.state == .drop { model.dragLeftZone() }
            return
        }
        let types = NSPasteboard(name: .drag).types ?? []
        guard types.contains(.fileURL) else { return }
        model.dragNear(isOverIsland: islandRect().contains(point))
    }

    // MARK: drops

    private func acceptDrop(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" {
            model.dragLeftZone()
            onDrop?(url)
        } else {
            model.rejectDrop()
            onReject?()
        }
    }

    private func openOutput(dual: Bool) {
        let path = dual ? model.dualPath : model.monoPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealOutput() {
        let path = model.monoPath.isEmpty ? model.dualPath : model.monoPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: queue feedback

    func jobStarted(fileName: String) {
        model.beginJob(fileName: fileName)
        startElapsedTimer()
    }

    func jobProgress(progress: Double, stage: String) {
        model.update(progress: progress, stage: stage)
    }

    func jobFinished(monoPath: String, dualPath: String) {
        model.finish(monoPath: monoPath, dualPath: dualPath)
        stopElapsedTimer()
        model.closeAfterDone()
    }

    func jobFailed(message: String) {
        model.fail(message: message)
        stopElapsedTimer()
    }

    func jobCancelled() {
        model.close()
        stopElapsedTimer()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .activity else { return }
                self.model.elapsed += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: demo

    /// `--demo-reject-at`: the island's drop handler, without the drag.
    func demoDrop(_ url: URL) {
        acceptDrop(url)
    }

    func applyDemoState(_ state: String) {
        switch state {
        case "drop": model.setDemoDrop()
        case "activity": model.setDemoActivity()
        case "done": model.setDemoDone()
        case "error": model.setDemoError()
        default: model.close()
        }
    }
}
