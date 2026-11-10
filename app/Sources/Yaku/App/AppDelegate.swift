import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import YakuCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel()
    let engine = EngineManager()
    let demo = DemoOptions.current
    let backdropController = BackdropController()

    lazy var store = TranslationStore()
    lazy var coordinator = TranslationCoordinator(engine: engine, store: store)
    lazy var managerModel = ManagerModel(store: store, engine: engine)
    lazy var pdfQueue = PDFQueue(store: store, engine: engine)

    private lazy var hud = HUDController(coordinator: coordinator)
    private lazy var overlay = OverlayController(engine: engine, store: store, coordinator: coordinator)

    private var menuBar: MenuBarController?
    private var panel: PanelWindow?
    private var notch: NotchController?
    private var hotKey: HotKeyManager?
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    /// The job the island is currently showing, so the start transition is
    /// noticed once.
    private var notchJobID: UUID?

    func applicationDidBecomeActive(_ notification: Notification) {
        let permissions = PermissionState.shared
        permissions.refresh()
        hud.refreshPermissions(accessibilityGranted: permissions.accessibilityGranted)
        overlay.refreshPermissions(screenRecordingGranted: permissions.screenRecordingGranted)
    }

    // MARK: launch

    /// The flags whose value is a sentence the user (or the demo) wants
    /// translated or searched for. Their values stay out of the log unless
    /// content logging is on.
    private static let textCarryingFlags: Set<String> = ["--demo-text", "--demo-translate", "--demo-search"]

    /// The launch arguments as the log may show them.
    static func loggableLaunchArguments() -> [String] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !AppLog.logsContent else { return arguments }
        var result: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext, !argument.hasPrefix("--") {
                result.append("<\(argument.count) chars>")
                redactNext = false
                continue
            }
            redactNext = textCarryingFlags.contains(argument)
            result.append(argument)
        }
        return result
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.rotateIfNeeded()
        AppLog.write("launch args=[\(Self.loggableLaunchArguments().joined(separator: " "))]")

        // SPEC 7.1: only one Yaku runs at a time. A second one exits at once,
        // before anything is set up, so it can never touch the engine record or
        // the store.
        guard SingleInstance.acquire() else {
            print("Perspica はすでに動いています")
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)
        installQuitHandler()
        // SwiftUI builds its menus after launch, so look twice.
        installQuitMenuItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.installQuitMenuItem()
        }

        if let appearance = demo.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            AppLog.write("appearance forced to \(appearance)")
        }

        let settings = AppSettings.shared
        if let idle = demo.engineIdleSeconds {
            engine.configure(idleSeconds: idle)
        } else {
            engine.configure(idleSeconds: settings.engineIdleSeconds)
        }
        // `--pdf-python` is the development escape hatch for the worker's
        // interpreter (SPEC 8.2).
        if let python = demo.pdfPython {
            settings.pdfPythonPath = python
            AppLog.write("pdf-worker: interpreter forced to \(python)")
        }

        // Headless translation run: no menu bar item, no panel.
        if let text = demo.translate {
            runTranslationDemo(text)
            return
        }

        // Headless reading run for `--demo-image --demo-dump-blocks`: the blocks
        // Vision found, as JSON, without a screen.
        if let path = demo.demoImage, demo.dumpBlocks {
            runDumpBlocksDemo(path)
            return
        }

        _ = store
        store.seedGlossaryIfNeeded()
        store.pruneHistory(olderThanDays: settings.historyRetentionDays)
        URLCacheLeftovers.remove()
        AppLog.write("store ready inMemory=\(store.isInMemory) history=\(store.historyCount) "
            + "cache=\(store.cacheCount) glossary=\(store.glossaryCount) "
            + "dataDir=\(AppPaths.isUsingDataDirectory)")

        setUpMenuBar()
        // SPEC 15: a light or dark picture behind the glass, so the
        // surfaces can be photographed over both without touching the Mac's
        // wallpaper. It sits below the app's own windows.
        if let backdrop = demo.backdrop {
            backdropController.show(backdrop)
        }
        // Recorded at launch because the permission cannot be granted or
        // checked without a keypress, and the log is the only way to see what
        // the selection hotkey would find.
        AppLog.write("accessibility trusted=\(AccessibilityPermission.isTrusted)")
        // A HUD demo should not leave the (invisible) panel window in the way
        // of a window-targeted screenshot. The overlay demos are the same: only
        // the overlay window should show up in a capture.
        if !demoHidesPanel {
            setUpPanel()
        }
        setUpHUD()
        setUpHotKeys()
        setUpMonitors()

        // SPEC 7.3: the screen overlay gives way to a dialogue request.
        coordinator.onDialogueRequestStarted = { [weak self] in
            self?.overlay.yieldToDialogue()
        }

        engine.onStateChange = { [weak self] state in
            self?.engineStateChanged(state)
        }

        setUpPDF()
        setUpDemo()

        if !settings.hasSeenOnboarding, demo.surface == nil, demo.downloadModelID == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WindowBridge.shared.openOnboarding()
            }
        }

        if let closeAfter = demo.closeWindowsAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + closeAfter) {
                let open = NSApp.windows.filter { $0.level == .normal && $0.isVisible }
                AppLog.write("demo: closing \(open.count) hand-opened window(s)")
                for window in open { window.close() }
            }
        }

        if let quitAfter = demo.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
                AppLog.write("demo quit after \(quitAfter)s")
                // A sheet that is still up keeps AppKit from finishing the
                // quit, so a demo run dismisses one first.
                self.managerModel.licenseModel = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Finder's 「このアプリで開く」 (SPEC 8.1, CFBundleDocumentTypes).
    func application(_ application: NSApplication, open urls: [URL]) {
        AppLog.write("open: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        // One task, in order, so the queue sees the files as the user did.
        Task {
            for url in pdfs {
                await enqueuePDF(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminate; stopping engine")
        pdfQueue.stopSynchronously()
        engine.stopSynchronously()
    }

    /// A sheet that is still up (the model licence) otherwise keeps AppKit from
    /// finishing the quit: `terminate` is accepted and then never happens.
    /// Closing the sheets first and answering `terminateNow` makes ⌘Q work in
    /// every state.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sheets = NSApp.windows.compactMap(\.attachedSheet)
        AppLog.write("terminate: asked, windows=\(NSApp.windows.count) sheets=\(sheets.count) "
            + "modal=\(NSApp.modalWindow != nil)")
        closeSheets()
        AppLog.write("terminate: replying terminateNow")
        return .terminateNow
    }

    private func closeSheets() {
        for window in NSApp.windows where window.attachedSheet != nil {
            if let sheet = window.attachedSheet {
                AppLog.write("terminate: closing a sheet")
                window.endSheet(sheet, returnCode: .cancel)
            }
        }
    }

    /// The Quit Apple Event (`osascript … to quit`, the Dock's 終了, the logout
    /// Apple Event) is answered by SwiftUI's own application delegate while a
    /// sheet is attached: it replies 「ユーザによってキャンセルされました」
    /// (-128) and never asks `applicationShouldTerminate`, so the app stayed
    /// running with the licence sheet up (SPEC 15). Answering the event
    /// here, before SwiftUI's delegate sees it, makes the quit work in every
    /// state.
    private func installQuitHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    /// SwiftUI's 終了 menu item is a scene command: while the licence sheet is
    /// the key window there is no active scene, so the item does nothing and
    /// the app could not be quit from the menu or with ⌘Q (SPEC 15). Point
    /// the item at AppKit directly.
    private func installQuitMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        for item in appMenu.items where item.keyEquivalent == "q" {
            item.target = self
            item.action = #selector(quitFromMenu)
            AppLog.write("quit item patched: \(item.title)")
            return
        }
    }

    @objc private func quitFromMenu() {
        AppLog.write("quit: menu item")
        closeSheets()
        NSApp.terminate(nil)
    }

    @objc private func handleQuitEvent(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        AppLog.write("quit event: closing sheets and terminating")
        closeSheets()
        NSApp.terminate(nil)
    }

    // MARK: menu bar

    private func setUpMenuBar() {
        let controller = MenuBarController()
        controller.onToggle = { [weak self] in
            self?.togglePanel(reason: "status-item", startedAt: CFAbsoluteTimeGetCurrent())
        }
        controller.onPause = { [weak self] in
            guard let self else { return }
            AppLog.write("menu: pause (stop engine)")
            Task { await self.engine.stop() }
        }
        controller.onOpenManager = { [weak self] in
            WindowBridge.shared.openManager(page: self?.managerPageForDemo)
        }
        controller.onOpenSettings = {
            WindowBridge.shared.openSettingsWindow()
        }
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onDragEntered = { [weak self] in
            guard let self else { return }
            self.model.isDropTarget = true
            self.model.dropHover = true
            self.openPanel(reason: "icon-drag")
        }
        controller.onDrop = { [weak self] url in
            guard let self else { return }
            self.model.dropHover = false
            self.model.isDropTarget = false
            Task { _ = await self.enqueuePDF(url) }
        }
        controller.onDragExited = { [weak self] in
            guard let self, !self.model.isPanelDropHovered else { return }
            self.model.dropHover = false
            self.model.isDropTarget = false
        }
        menuBar = controller
    }

    private func engineStateChanged(_ state: EngineManager.State) {
        switch state {
        case .starting:
            menuBar?.setEngineBusy(true)
        case .failed:
            menuBar?.setEngineBusy(false)
            menuBar?.setPDFBadge(.failed)
        case .running, .stopped:
            menuBar?.setEngineBusy(false)
        }
    }

    // MARK: panel

    private func setUpPanel() {
        let hosting = PanelContainerView(
            model: model,
            coordinator: coordinator,
            pdf: pdfQueue,
            onOpenPDF: { [weak self] in self?.choosePDF() },
            onScreenTranslate: { [weak self] in
                // The panel stays open behind the picker (SPEC 4.6 の 1).
                self?.overlay.begin()
            }
        )
        hosting.onDrop = { [weak self] url in
            Task { _ = await self?.enqueuePDF(url) }
        }
        hosting.onReject = { [weak self] in
            self?.shakePanelForRejection()
        }
        hosting.frame = CGRect(origin: .zero, size: PanelLayout.windowSize)

        let panel = PanelWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
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
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        panel.orderFrontRegardless()

        self.panel = panel
        positionPanel()
        AppLog.write("panel created frame=\(panel.frame)")
    }

    private func setUpHUD() {
        hud.onOpenPanel = { [weak self] in
            guard let self else { return }
            self.openPanel(reason: "hud-open-in-panel")
        }
    }

    private func togglePanel(reason: String, startedAt: CFAbsoluteTime) {
        if model.isOpen {
            closePanel(reason: reason)
        } else {
            openPanel(reason: reason, startedAt: startedAt)
        }
    }

    private func openPanel(reason: String, startedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard let panel else { return }
        guard !model.isOpen else { return }

        positionPanel()
        model.isOpen = true
        if model.autoFocusEnabled { model.focusRequest += 1 }
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)

        // SPEC 4.1: the failure dot clears when the panel is opened.
        menuBar?.setPDFBadge(.none)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        AppLog.write(String(format: "panel open (%@) %.1fms from action to orderFront", reason, elapsed))

        // SPEC 7.1: the engine starts when the panel is opened.
        Task { [engine] in
            _ = await engine.ensureRunning()
        }
    }

    private func closePanel(reason: String) {
        guard model.isOpen else { return }
        model.isOpen = false
        model.isDropTarget = false
        model.dropHover = false
        model.isPanelDropHovered = false
        panel?.ignoresMouseEvents = true
        panel?.resignKey()
        AppLog.write("panel close (\(reason))")
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = screenForPanel()
        let size = PanelLayout.windowSize
        let shapeTop = menuBarBottom(for: screen) - PanelLayout.gapBelowMenuBar

        let anchorX = statusItemFrame?.midX ?? screen.frame.midX
        let minX = screen.frame.minX + PanelLayout.screenEdgeInset - PanelLayout.shadowMargin
        let maxX = screen.frame.maxX - PanelLayout.screenEdgeInset
            - PanelLayout.width - PanelLayout.shadowMargin
        let x = min(max(anchorX - size.width / 2, minX), max(maxX, minX))

        panel.setFrame(
            CGRect(x: x, y: shapeTop - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    /// The status item's window, but only once AppKit has laid it out. At
    /// launch it can still report a zero-height frame at the origin.
    private var statusItemFrame: NSRect? {
        guard let frame = menuBar?.buttonFrame, frame.height > 0 else { return nil }
        return frame
    }

    private func screenForPanel() -> NSScreen {
        if let frame = statusItemFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// The bottom of the menu bar, which is where the panel hangs from.
    ///
    /// This is deliberately `visibleFrame.maxY` rather than the status item's
    /// window frame: on the primary display that frame reported a y above the
    /// screen's top edge, which put the panel off-screen. `visibleFrame`
    /// already excludes the menu bar, so its top edge is exactly the menu bar's
    /// bottom.
    private func menuBarBottom(for screen: NSScreen) -> CGFloat {
        screen.visibleFrame.maxY
    }

    // MARK: hotkeys

    private func setUpHotKeys() {
        let manager = HotKeyManager()
        hotKey = manager
        registerHotKeys()
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .yakuShortcutsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
    }

    private func registerHotKeys() {
        guard let hotKey else { return }
        hotKey.update(
            bindings: AppSettings.shared.shortcutBindings,
            actions: [
                HotKeyManager.selectionID: { [weak self] in self?.selectionHotKey() },
                HotKeyManager.panelID: { [weak self] in
                    // Start the clock inside the hotkey handler, so the logged
                    // number covers the whole path the user waits through.
                    self?.togglePanel(reason: "hotkey", startedAt: CFAbsoluteTimeGetCurrent())
                },
                HotKeyManager.screenID: { [weak self] in
                    self?.screenHotKey()
                },
            ]
        )
    }

    /// ⌃⌥J: read the selection and translate it in the HUD (SPEC 4.3).
    private func selectionHotKey() {
        let started = CFAbsoluteTimeGetCurrent()
        AppLog.write("hotkey ⌃⌥J")

        // SPEC 7.1: the engine begins loading on the hotkey too.
        engine.warmUp()

        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.promptOnce()
            hud.showPermissionNeeded()
            AppLog.write("hud: no accessibility permission")
            return
        }
        guard let capture = SelectionReader.capture() else {
            hud.showNoSelection()
            return
        }
        hud.show(capture: capture, anchor: capture.bounds)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        AppLog.write(String(format: "hud shown %.1fms after hotkey", elapsed))
    }

    /// ⌃⌥O: pick a region, read it and lay the translation over the screen
    /// (SPEC 4.6).
    private func screenHotKey() {
        AppLog.write("hotkey ⌃⌥O")
        // SPEC 7.1: the hotkey begins loading the model right away.
        engine.warmUp()
        overlay.begin()
    }

    // MARK: monitors

    private func setUpMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.type == .scrollWheel {
                        if !(event.window is HUDWindow) { self.hud.hide(reason: "selection scrolled") }
                    } else {
                        if event.window !== self.panel, self.model.isOpen, !self.model.isPinned {
                            self.closePanel(reason: "own-window outside click")
                        }
                        if !(event.window is HUDWindow), !self.demo.pin {
                            self.hud.hide(reason: "own-window outside click")
                        }
                    }
                }
                return event
            }
        ) { monitors.append(local) }
        // Clicks inside the panel or HUD are delivered to our own app, so
        // anything the global monitor sees is outside them.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .flagsChanged],
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleGlobalEvent(event) }
            }
        ) {
            monitors.append(global)
        }

        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                // Key monitors run on the main thread; only a Bool crosses back.
                let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return consumed ? nil : event
            }
        ) {
            monitors.append(keys)
        }

        // ⌥ held shows the source in the HUD (SPEC 4.3).
        if let flags = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    self?.coordinator.optionDown = event.modifierFlags.contains(.option)
                }
                return event
            }
        ) {
            monitors.append(flags)
        }

        // The HUD closes when another app comes to the front (SPEC 4.3).
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.demo.pin else { return }
                guard let activated, activated.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.hud.hide(reason: "front app changed")
            }
        }
    }

    private func handleOutsideClick() {
        if hud.isVisible, !demo.pin {
            hud.hide(reason: "outside-click")
        }
        guard model.isOpen, !model.isPinned else { return }
        closePanel(reason: "outside-click")
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            if !demo.pin { hud.hide(reason: "selection scrolled") }
        case .flagsChanged:
            coordinator.optionDown = event.modifierFlags.contains(.option)
        case .leftMouseDown, .rightMouseDown:
            handleOutsideClick()
        case .leftMouseDragged:
            handleIconDrag()
        case .leftMouseUp:
            // The drop is delivered on mouse-up, so the state is cleared a
            // moment later, and only if nothing landed.
            guard model.isDropTarget else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.model.isDropTarget, !self.model.dropHover else { return }
                self.model.isDropTarget = false
            }
        default:
            break
        }
    }

    /// SPEC 4.1: a file dragged over the menu bar icon opens the panel in the
    /// drop state, which is then the drop target.
    private func handleIconDrag() {
        guard !model.isDropTarget else { return }
        // Every drag anywhere on the Mac lands here, so the cheap position
        // test goes first: reading the drag pasteboard is a round trip to the
        // pasteboard server, about 1 ms (perf review 2026-11-09).
        guard let frame = menuBar?.buttonFrame, frame.height > 0 else { return }
        guard frame.insetBy(dx: -14, dy: -8).contains(NSEvent.mouseLocation) else { return }
        let types = NSPasteboard(name: .drag).types ?? []
        guard types.contains(.fileURL) else { return }

        AppLog.write("panel: file dragged over the status item")
        model.dropMessage = PanelModel.dropPrompt
        model.dropHover = false
        model.isDropTarget = true
        openPanel(reason: "icon-drag")
    }

    /// Returns true when the panel or HUD handled the key and it should not
    /// travel on.
    private func handleKey(_ event: NSEvent) -> Bool {
        if hud.isKeyWindow {
            return handleHUDKey(event)
        }
        guard model.isOpen, panel?.isKeyWindow == true else { return false }
        return handlePanelKey(event)
    }

    private func handlePanelKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            closePanel(reason: "esc")
            return true
        case 36, 76: // return / enter
            if matches(event, modifiers: [.command]) {
                coordinator.translatePanel()
                return true
            }
        case 8: // C
            if matches(event, modifiers: [.command, .shift]) {
                coordinator.copyTranslation(on: .panel)
                return true
            }
        case 2: // D
            if matches(event, modifiers: [.command]) {
                coordinator.swapLanguages()
                return true
            }
        case 35: // P
            if matches(event, modifiers: [.command]) {
                withAnimation(.snappy(duration: 0.25)) { model.isPinned.toggle() }
                return true
            }
        case 45: // N
            if matches(event, modifiers: [.command]) {
                coordinator.openPanelInManager()
                closePanel(reason: "open manager")
                return true
            }
        case 31: // O
            if matches(event, modifiers: [.command]) {
                choosePDF()
                return true
            }
        default:
            break
        }
        return false
    }

    private func handleHUDKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            hud.hide(reason: "esc")
            return true
        case 48: // tab
            if matches(event, modifiers: [.control]) {
                NSApp.keyWindow?.selectNextKeyView(nil)
                return true
            }
            guard matches(event, modifiers: []) else { return false }
            coordinator.toggleFormAndRetranslateHUD()
            return true
        case 36, 76: // return / enter
            if matches(event, modifiers: [.command]) {
                hud.replaceSelection()
                return true
            }
        case 8: // C
            if matches(event, modifiers: [.command]) {
                coordinator.copyTranslation(on: .hud)
                return true
            }
        case 31: // O
            if matches(event, modifiers: [.command]) {
                hud.openInPanel()
                return true
            }
        default:
            break
        }
        return false
    }

    private func matches(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
    }

    /// `--demo-copy-at`: ⌘C when the HUD is the key window, ⌘⇧C otherwise,
    /// posted to the app's own queue so `handleKey` sees it like a press.
    private func postDemoCopyKey() {
        let modifiers: NSEvent.ModifierFlags = hud.isKeyWindow ? [.command] : [.command, .shift]
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ) else { return }
        AppLog.write("demo: copy key \(hud.isKeyWindow ? "⌘C (HUD)" : "⌘⇧C (panel)")")
        NSApp.postEvent(event, atStart: false)
    }

    /// `--demo-click`: a mouse down and up at `point` (from the top left) of
    /// the frontmost normal window, posted to the app's own queue.
    private func postDemoClick(at point: CGPoint) {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.level == .normal }) else {
            AppLog.write("demo: click with no window to click")
            return
        }
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        AppLog.write("demo: click at \(Int(point.x)),\(Int(point.y)) in window \(window.windowNumber)")
    }

    // MARK: PDF (SPEC 8)

    private func setUpPDF() {
        pdfQueue.onNeedsWorker = { [weak self] update in
            self?.promptForWorkerInstall(update: update)
        }
        PDFNotifications.shared.onOpen = { path in
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        pdfQueue.onProgress = { [weak self] job in
            self?.pdfProgress(job)
        }
        pdfQueue.onFinished = { [weak self] job in
            self?.pdfFinished(job)
        }
        pdfQueue.onRejected = { [weak self] message in
            self?.pdfRejected(message)
        }
        // The target for a PDF follows the panel's rule: a language pair the
        // user set wins; otherwise the 既定の目的の言語 setting, unless the
        // document is already in it, in which case SPEC 5.1's ja/en rule.
        pdfQueue.resolveTarget = { [weak self] source in
            if let pair = self?.coordinator.manualPair, pair.source == nil || pair.source == source {
                return pair.target
            }
            let preferred = AppSettings.shared.defaultTargetLanguage
            return preferred != source ? preferred : LanguageDetector.defaultTarget(forSource: source)
        }

        let controller = NotchController()
        controller.onDrop = { [weak self] url in
            Task { _ = await self?.enqueuePDF(url) }
        }
        controller.onReject = { [weak self] in
            self?.shakePanelForRejection()
        }
        controller.onRetry = { [weak self] in
            guard let self, let job = self.pdfQueue.recentlyFailed else { return }
            self.pdfQueue.retry(job)
        }
        notch = controller
        let forced = demo.surface == "notch"
        // An overlay or HUD demo is photographed on its own, so the island
        // window is left out of it.
        let notchEnabled = !demoHidesPanel && (forced || AppSettings.shared.useNotch)
        controller.setUp(enabled: notchEnabled, force: forced)
        observeNotchSetting()
    }

    private func observeNotchSetting() {
        withObservationTracking {
            _ = AppSettings.shared.useNotch
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.notch?.setUp(enabled: !self.demoHidesPanel && AppSettings.shared.useNotch)
                if AppSettings.shared.useNotch, let job = self.pdfQueue.activeJob {
                    self.notchJobID = nil
                    self.pdfProgress(job)
                }
                self.observeNotchSetting()
            }
        }
    }

    private func pdfProgress(_ job: PDFJob) {
        guard job.jobState == .running else { return }
        if notchJobID != job.id {
            notchJobID = job.id
            notch?.jobStarted(fileName: job.fileName)
        }
        menuBar?.setPDFBadge(.progress(job.progress))
        notch?.jobProgress(progress: job.progress, stage: job.stage)
    }

    private func pdfFinished(_ job: PDFJob) {
        notchJobID = nil
        switch job.jobState {
        case .done:
            menuBar?.setPDFBadge(.finished)
            // SPEC 4.1: the bounce happens once, then the progress disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.menuBar?.setPDFBadge(.none)
            }
            notch?.jobFinished(monoPath: job.outputMonoPath, dualPath: job.outputDualPath)
            if AppSettings.shared.pdfOpenWhenDone, !job.outputMonoPath.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: job.outputMonoPath))
            }
            if !model.isOpen {
                PDFNotifications.shared.notifyFinished(fileName: job.fileName, path: job.outputMonoPath)
            }
        case .failed:
            menuBar?.setPDFBadge(.failed)
            notch?.jobFailed(message: job.errorMessage)
        case .cancelled:
            menuBar?.setPDFBadge(.none)
            notch?.jobCancelled()
        default:
            break
        }
    }

    private func pdfRejected(_ message: String) {
        guard model.isOpen else { return }
        model.rejectDrop(message: message)
    }

    /// The panel's own drop refused a file: show the wording and shake once
    /// (SPEC 4.2).
    private func shakePanelForRejection() {
        model.isDropTarget = true
        model.rejectDrop(message: "PDF だけ対応しています")
    }

    /// ⌘O and the panel's 「PDF を開く…」.
    func choosePDF() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.pdf]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.prompt = "訳す"
        if picker.runModal() == .OK, let url = picker.url {
            Task { _ = await enqueuePDF(url) }
        }
    }

    /// The one path every entry point takes into the queue.
    @discardableResult
    func enqueuePDF(_ url: URL, pages: String? = nil) async -> PDFQueue.EnqueueResult {
        let result = await pdfQueue.enqueue(url: url, pages: pages)
        switch result {
        case .needsWorker:
            promptForWorkerInstall(update: false)
        case .needsWorkerUpdate:
            promptForWorkerInstall(update: true)
        case .accepted, .waitingForWorker, .rejected:
            break
        }
        return result
    }

    /// True while the install question is on screen, so a second file that
    /// arrives meanwhile waits in the queue instead of asking again.
    private var isAskingForWorkerInstall = false

    /// SPEC 8.2 / 13: the first PDF asks before the extra parts are fetched.
    /// `update` is the same question for an environment that has to be synced
    /// to new requirements. The queue runs the waiting files when the
    /// installer finishes, whichever surface started it.
    private func promptForWorkerInstall(update: Bool) {
        guard !isAskingForWorkerInstall, pdfQueue.installer.phase != .running else { return }
        // A `--demo-pdf` run is scripted and unattended, so the question is
        // treated as already answered; the Settings PDF tab keeps the button.
        if demo.pdf != nil {
            AppLog.write("pdf-worker: install question skipped (demo)")
            Task { await pdfQueue.installer.install() }
            return
        }

        isAskingForWorkerInstall = true
        defer { isAskingForWorkerInstall = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if update {
            alert.messageText = "PDF の翻訳に使う部品を更新します"
            alert.informativeText = "新しい版の取得に数分かかります。"
            alert.addButton(withTitle: "更新する")
        } else {
            alert.messageText = "PDF の翻訳には追加の部品が必要です"
            alert.informativeText = "約 \(PDFWorkerInstaller.estimatedSizeText)、取得に数分かかります。"
            alert.addButton(withTitle: "取得する")
        }
        alert.addButton(withTitle: "やめる")
        AppLog.write("pdf-worker: prompting for \(update ? "sync" : "install")")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await pdfQueue.installer.install() }
        } else {
            AppLog.write("pdf-worker: install declined")
            pdfQueue.discardPendingIntakes()
        }
    }

    // MARK: demo surfaces

    /// `--demo-surface manager --demo-page pdf --demo-state …`: a row on the
    /// manager's PDF page without running the worker.
    private func applyManagerPDFDemo() {
        switch demo.state {
        case "done":
            pdfQueue.applyDemoJob(state: .done, progress: 1, stage: "Save PDF")
            // A failed row as well, with a long worker error, so the one-line
            // row and its 詳細 popover can be photographed.
            pdfQueue.applyDemoJob(
                state: .failed, progress: 0.31, stage: "Translate Paragraphs",
                fileName: "manual.pdf", pageCount: 42,
                errorMessage: "PDF を訳せませんでした: ModuleNotFoundError: "
                    + "No module named 'babeldoc'（設定の「PDF」からワーカーを入れ直してください）"
            )
        case "pdf-running", "running":
            pdfQueue.applyDemoJob(state: .running, progress: 0.42, stage: "Translate Paragraphs")
        case "failed":
            pdfQueue.applyDemoJob(state: .failed, progress: 0.31, stage: "Translate Paragraphs")
        case "queued":
            pdfQueue.applyDemoJob(state: .queued, progress: 0, stage: "Preparing")
        default:
            break
        }
    }

    /// `--demo-page` when it names a manager page.
    private var managerPageForDemo: ManagerSection? {
        guard demo.surface == "manager", let page = demo.page else { return nil }
        return ManagerSection(rawValue: page)
    }

    /// True when the demo shows a surface that should be photographed on its
    /// own, so the always-created panel and island windows are left out.
    private var demoHidesPanel: Bool {
        if demo.demoImage != nil { return true }
        switch demo.surface {
        case "hud", "overlay", "overlay-picker": return true
        default: return false
        }
    }

    private func setUpDemo() {
        let text = demo.text ?? DemoText.threeParagraphs

        // SPEC 15: the accessibility looks and the installed PDF worker
        // are shown through launch options, never by changing the Mac's own
        // settings.
        AppearanceOverrides.reduceMotionDemo = demo.reduceMotionDemo
        AppearanceOverrides.reduceTransparencyDemo = demo.reduceTransparencyDemo
        AppearanceOverrides.increaseContrastDemo = demo.increaseContrastDemo
        PDFWorkerPaths.demoInstalled = demo.pdfWorkerDemoInstalled

        if demo.pin {
            model.isPinned = true
            AppLog.write("demo: panel pinned")
        }
        if demo.surface == "panel", demo.state == "translating" || demo.state == "done" {
            model.autoFocusEnabled = false
        }

        // `--demo-pdf` goes through the same intake as a drop (SPEC 15). The
        // option may be given more than once, which stands in for several
        // files opened together from Finder.
        if demo.pdf != nil {
            let arguments = CommandLine.arguments
            let paths = arguments.indices.dropLast()
                .filter { arguments[$0] == "--demo-pdf" }
                .map { arguments[$0 + 1] }
            AppLog.write("demo-pdf: \(paths.count) file(s) pages=\(demo.pdfPages ?? "-")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                Task { [weak self] in
                    for path in paths {
                        await self?.enqueuePDF(URL(fileURLWithPath: path), pages: self?.demo.pdfPages)
                    }
                }
            }
        }

        // `--demo-translate-after`: a panel translation that lands while a PDF
        // job is running, so the two are seen to share the engine (SPEC 7.3).
        if let delay = demo.translateAfter {
            AppLog.write("demo: panel translation after \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.coordinator.panel.sourceText = text
                self.coordinator.translatePanel()
            }
        }

        // `--demo-cancel-after`: 取り消し on the running job, without a click.
        if let delay = demo.cancelAfter {
            AppLog.write("demo: cancelling the PDF job after \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let job = self.pdfQueue.running else {
                    AppLog.write("demo: nothing to cancel")
                    return
                }
                self.pdfQueue.cancel(job)
            }
        }

        // `--demo-copy-at`: the copy shortcut, pressed at those times.
        for time in demo.copyAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                self?.postDemoCopyKey()
            }
        }

        // `--demo-reject-at`: a file that is not a PDF, dropped on the island.
        for time in demo.rejectAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                AppLog.write("demo: a text file dropped on the island")
                self?.notch?.demoDrop(URL(fileURLWithPath: "/tmp/notes.txt"))
            }
        }

        // `--demo-snapshot-at`: the visible windows, drawn into PNGs.
        for time in demo.snapshotAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                WindowSnapshot.writeAll(label: String(format: "t%05.2f", time))
            }
        }

        // `--demo-click` / `--demo-click-at`: a click on that point.
        if let point = demo.clickPoint {
            for time in demo.clickAt {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                    self?.postDemoClick(at: point)
                }
            }
        }

        // `--demo-image <png>`: read a file instead of the screen and lay the
        // translation over it, from the screen's top left (SPEC 15).
        if let path = demo.demoImage {
            let scale = demo.demoScale ?? 1
            AppLog.write("demo-image: \(path) scale=\(scale)")
            // The real path warms the engine when ⌃⌥O is pressed and the user
            // spends a moment on the picker, so the demo warms it here and waits
            // the same way (SPEC 7.1, 14).
            engine.warmUp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.overlay.showImage(path: path, scale: scale)
            }
            return
        }

        if let modelID = demo.downloadModelID {
            runDownloadDemo(modelID: modelID)
            return
        }

        switch demo.surface {
        case "hud":
            if demo.state == "no-permission" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.hud.showPermissionNeeded()
                }
            } else {
                let anchor = demo.anchor.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) }
                let hudText = demo.text ?? DemoText.selectionSample
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.hud.showDemoText(hudText, anchor: anchor)
                }
            }

        case "manager":
            if let page = demo.page, let section = ManagerSection(rawValue: page) {
                ManagerState.shared.section = section
            }
            if demo.page == "pdf" {
                applyManagerPDFDemo()
            }
            if let search = demo.search {
                managerModel.historySearch = search
                AppLog.write("demo: history search (\(search.count) chars)")
                AppLog.content("demo: history search=\(search)")
            }
            if demo.state == "done" || demo.state == "translating" {
                coordinator.manager.sourceText = text
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                WindowBridge.shared.openManager(page: self.managerPageForDemo)
                if self.demo.state == "done" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.coordinator.translateManager()
                    }
                }
            }

        case "settings":
            if let tab = demo.tab, let parsed = SettingsTab.named(tab) {
                SettingsState.shared.tab = parsed
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                WindowBridge.shared.openSettingsWindow()
            }

        case "onboarding":
            AppLog.write("demo: onboarding page=\(demo.page ?? "1")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                WindowBridge.shared.openOnboarding()
            }

        case "panel":
            if let glowSeconds = demo.glowSeconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.openPanel(reason: "demo-glow")
                    self.coordinator.applyDemoGlow()
                    AppLog.write("demo: glow for \(glowSeconds)s")
                }
                return
            }

            switch demo.state {
            case "translating":
                // A real translation is run over and over with the light held
                // on, so the state is genuine rather than faked (SPEC 15).
                coordinator.panel.sourceText = text
                coordinator.demoRepeat = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.openPanel(reason: "demo-surface")
                    self.coordinator.translatePanel()
                }
            case "done":
                coordinator.panel.sourceText = text
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.openPanel(reason: "demo-surface")
                    self.coordinator.translatePanel()
                }
            case "error":
                coordinator.applyDemoFailure(.engineStartFailed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.openPanel(reason: "demo-surface")
                }
            case "drop":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.model.dropMessage = PanelModel.dropPrompt
                    self.model.isDropTarget = true
                    self.openPanel(reason: "demo-surface")
                }
            case "pdf-running":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.pdfQueue.applyDemoJob(
                        state: .running,
                        progress: 0.42,
                        stage: "Translate Paragraphs"
                    )
                    self.openPanel(reason: "demo-surface")
                }
            case "pdf-done":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.pdfQueue.applyDemoJob(state: .done, progress: 1, stage: "Save PDF")
                    self.openPanel(reason: "demo-surface")
                }
            default:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.openPanel(reason: "demo-surface")
                }
            }

        case "notch":
            AppLog.write("demo: notch state=\(demo.state ?? "closed")")
            if let state = demo.state {
                notch?.applyDemoState(state)
            }

        case "overlay":
            // SPEC 15: the overlay with no screen to capture. `--demo-image`
            // handles the drawn state; this is the empty and permission states.
            AppLog.write("demo: overlay state=\(demo.state ?? "empty")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                switch self.demo.state {
                case "permission":
                    self.overlay.showPermissionDemo()
                default:
                    self.overlay.showEmptyDemo()
                }
            }

        case "overlay-picker":
            AppLog.write("demo: overlay picker")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.overlay.showPickerDemo()
            }

        case "icon":
            // The menu bar icon's three PDF badges (SPEC 4.1), without waiting
            // for a real job.
            switch demo.state {
            case "done":
                menuBar?.setPDFBadge(.finished)
            case "failed":
                menuBar?.setPDFBadge(.failed)
            default:
                menuBar?.setPDFBadge(.progress(0.42))
            }
            AppLog.write("demo: menu bar badge=\(demo.state ?? "progress")")

        default:
            if demo.glowSeconds != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.openPanel(reason: "demo-glow")
                    self.coordinator.applyDemoGlow()
                }
            } else if demo.surface == nil && demo.state == nil {
                AppLog.write("launch: idle")
            }
        }
    }

    // MARK: headless demo

    /// `--demo-download <id>`: opens the model page and fetches the model, so
    /// the resume, the progress and the SHA-256 check can be checked without
    /// clicking (SPEC 15). `--demo-download-cancel <秒>` stops it half way.
    private func runDownloadDemo(modelID: String) {
        guard let target = ModelCatalog.model(id: modelID) else {
            AppLog.write("demo-download: unknown model \(modelID)")
            return
        }
        ManagerState.shared.section = .models
        if !demo.downloadGate {
            AppSettings.shared.acceptLicense(for: target.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            WindowBridge.shared.openManager(page: .models)
            AppLog.write("demo-download: request \(target.id) gate=\(self.demo.downloadGate)")
            self.managerModel.requestDownload(target)
            if let cancelAfter = self.demo.downloadCancelAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + cancelAfter) {
                    AppLog.write("demo-download: cancel after \(cancelAfter)s")
                    self.managerModel.cancelDownload()
                }
            }
        }
    }

    /// `--demo-image <png> --demo-dump-blocks`: print the blocks Vision read as
    /// JSON and exit, so the reading can be checked without a screen.
    private func runDumpBlocksDemo(_ path: String) {
        Task {
            guard let image = ScreenCapturer.loadImage(at: path) else {
                print("画像を読み込めませんでした: \(path)")
                AppLog.write("dump-blocks: could not read \(path)")
                NSApp.terminate(nil)
                return
            }
            let language = AppSettings.shared.overlayLanguage
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let lines = try await ScreenOCR.lines(in: image, language: language)
                let pixels = PixelImage(cgImage: image)
                let sizeOf: (OCRLine) -> CGFloat? = { line in
                    guard let pixels else { return nil }
                    return TextInk.fontSize(in: pixels, line: line.rect, text: line.text)
                }
                let blocks = OCRBlockBuilder.blocks(from: lines, sizeOf: sizeOf)
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                // Every line Vision found, with its box and its measured size,
                // so a line that was left out of a block can be seen next to
                // the block it should have joined.
                func lineJSON(_ line: OCRLine) -> [String: Any] {
                    [
                        "text": line.text,
                        "size": sizeOf(line).map { ($0 * 100).rounded() / 100 } ?? NSNull(),
                        "confidence": line.confidence,
                        "rect": [
                            "x": Double(line.rect.minX),
                            "y": Double(line.rect.minY),
                            "width": Double(line.rect.width),
                            "height": Double(line.rect.height),
                        ],
                    ]
                }
                let payload: [String: Any] = [
                    "image": path,
                    "pixels": ["width": image.width, "height": image.height],
                    "language": language,
                    "seconds": elapsed,
                    "lineCount": lines.count,
                    "blockCount": blocks.count,
                    "lines": lines.map(lineJSON),
                    "blocks": blocks.enumerated().map { index, block -> [String: Any] in
                        [
                            "index": index,
                            "text": block.text,
                            "lines": block.lines.count,
                            // Each line's measured size, for checking the size rule.
                            "sizes": block.lines.map { line -> Any in
                                guard let size = sizeOf(line) else { return NSNull() }
                                return (size * 100).rounded() / 100
                            },
                            "confidence": block.confidence,
                            "rect": [
                                "x": Double(block.rect.minX),
                                "y": Double(block.rect.minY),
                                "width": Double(block.rect.width),
                                "height": Double(block.rect.height),
                            ],
                        ]
                    },
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(data: data, encoding: .utf8) ?? "{}")
                AppLog.write(String(format: "dump-blocks: %d lines → %d blocks in %.3fs (%@)",
                                    lines.count, blocks.count, elapsed, path))
            } catch {
                print("読み取れませんでした: \(error)")
                AppLog.write("dump-blocks: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    /// `--demo-translate "<文>"`: translate one text and exit.
    ///
    /// This goes through the same store and the same glossary as the panel, so
    /// it is a fair way to check that the glossary reaches the prompt.
    private func runTranslationDemo(_ text: String) {
        Task {
            let started = CFAbsoluteTimeGetCurrent()
            let ok = await engine.ensureRunning()
            guard ok else {
                print("エンジンを起動できませんでした: \(engine.state)")
                AppLog.write("demo-translate: engine failed \(engine.state)")
                NSApp.terminate(nil)
                return
            }
            let engineReady = CFAbsoluteTimeGetCurrent() - started
            AppLog.write(String(format: "demo-translate engine ready in %.2fs", engineReady))

            let glossary = demo.glossaryEnabled
                ? GlossaryFilter.relevant(store.enabledGlossaryPairs(), in: text)
                : []
            let sourceLanguage = LanguageDetector.resolve(text: text, previous: nil)
            let target = coordinator.resolvedTarget(forSource: sourceLanguage)
            let request = PFML3.request(
                source: text,
                sourceLanguage: sourceLanguage,
                targetLanguage: target,
                form: target == "ja" ? coordinator.form : nil,
                glossary: glossary
            )
            AppLog.write("demo-translate glossary=\(glossary.count) chars=\(text.count)")
            AppLog.content("demo-translate text=\(text)")

            let translateStart = CFAbsoluteTimeGetCurrent()
            var firstPiece: Double?
            var collected = ""
            do {
                for try await piece in engine.stream(request, priority: .interactive) {
                    if firstPiece == nil { firstPiece = CFAbsoluteTimeGetCurrent() - translateStart }
                    collected += piece
                }
            } catch {
                print("翻訳に失敗しました: \(error)")
                AppLog.write("demo-translate: \(error)")
                await engine.stop()
                NSApp.terminate(nil)
                return
            }
            let total = CFAbsoluteTimeGetCurrent() - translateStart
            let translation = TranslationCleanup.clean(collected)
            let first = firstPiece ?? -1

            print("原文: \(text)")
            print("用語集: \(glossary.map { "\($0.source)→\($0.target)" }.joined(separator: ", "))")
            print("訳文: \(translation)")
            print(String(format: "最初の文字: %.3f 秒 / 全体: %.3f 秒", first, total))
            AppLog.write(String(format: "demo-translate engineStartup=%.2fs first=%.3fs total=%.3fs chars=%d", engineReady, first, total, text.count))
            AppLog.content("demo-translate source=\(text)")
            AppLog.content("demo-translate result=\(translation)")

            await engine.stop()
            AppLog.write("demo-translate done")
            NSApp.terminate(nil)
        }
    }
}
