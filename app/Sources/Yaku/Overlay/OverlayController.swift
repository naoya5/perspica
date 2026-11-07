import AppKit
import CoreGraphics
import Foundation
import YakuCore

/// Owns the whole F4 flow (SPEC 4.6): the region picker, the capture, the text
/// reading, the translation and the overlay window that draws the result.
///
/// The overlay is a still picture of the moment it was taken, so it goes away
/// 200ms after the screen changes underneath it (scroll, a window moving, an app
/// switching) — SPEC 4.6 の 5.
@MainActor
final class OverlayController {
    let model = OverlayModel()

    private let coordinator: TranslationCoordinator
    private let translator: OverlayTranslator
    private let picker = OverlayPickerController()

    private var window: OverlayWindow?
    private var monitors: [Any] = []
    private var dismissTask: Task<Void, Never>?
    /// When the current run began, so the time from the capture to the first and
    /// the last block being drawn can be logged (SPEC 14 の F4 の目標).
    private var runStarted: CFAbsoluteTime = 0
    private var firstBlockLogged = false
    /// True between the picker opening and the overlay going away, so a second
    /// hotkey press is ignored rather than stacking pickers.
    private(set) var isActive = false

    init(engine: EngineManager, store: TranslationStore, coordinator: TranslationCoordinator) {
        self.coordinator = coordinator
        self.translator = OverlayTranslator(engine: engine, store: store)

        picker.onSelect = { [weak self] rect in
            self?.startCapture(rect: rect)
        }
        picker.onCancel = { [weak self] in
            self?.finish(reason: "picker cancelled")
        }
        translator.onTranslation = { [weak self] index, translation in
            self?.apply(translation, to: index)
        }
        translator.onFinished = { [weak self] completed in
            guard let self, completed else { return }
            // Nothing came back at all: say so rather than leaving the band on a
            // blank screen (SPEC 13 の文言に合わせる).
            if self.model.translatedCount == 0 {
                self.model.blocks = []
                self.model.hitRects = []
                self.model.phase = .failed("翻訳できませんでした")
                AppLog.write("overlay: no block could be translated")
                return
            }
            self.model.phase = .showing
            let elapsed = CFAbsoluteTimeGetCurrent() - self.runStarted
            AppLog.write(String(format: "overlay: all %d block(s) drawn %.3fs after capture",
                                self.model.translatedCount, elapsed))
        }
    }

    // MARK: starting

    /// ⌃⌥O and the panel's 「画面を翻訳」 (SPEC 4.6 の 1).
    func begin() {
        guard !isActive else {
            AppLog.write("overlay: already active")
            return
        }
        // The permission is asked for right before the first capture and only
        // once (SPEC 10).
        guard ScreenRecordingPermission.isGranted || ScreenRecordingPermission.requestOnce() else {
            AppLog.write("overlay: screen recording permission missing")
            showPermissionNotice()
            return
        }
        isActive = true
        model.reset()
        model.phase = .picking
        picker.show()
    }

    /// `--demo-surface overlay-picker`: the picker on its own (SPEC 15).
    func showPickerDemo() {
        isActive = true
        model.reset()
        model.phase = .picking
        picker.show()
    }

    /// SPEC 7.3: a dialogue request takes the engine ahead of the screen
    /// overlay, so its translations stop. The overlay itself stays up with
    /// whatever has already been drawn.
    func yieldToDialogue() {
        guard translator.isRunning else { return }
        translator.cancel(notify: false)
        AppLog.write("overlay: gave way to a dialogue request")
    }

    // MARK: capture

    private func startCapture(rect: CGRect) {
        model.phase = .reading
        showWindow(on: ScreenGeometry.screen(containingCGRect: rect))
        let started = CFAbsoluteTimeGetCurrent()
        runStarted = started
        firstBlockLogged = false

        Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await ScreenCapturer.capture(rect: rect)
                try await self.read(capture: capture, started: started)
            } catch {
                AppLog.write("overlay: capture failed \(error)")
                self.fail(ScreenRecordingPermission.isGranted
                    ? "画面を読み取れませんでした: \(error.localizedDescription)"
                    : "画面の文字を読むには、画面収録の許可が必要です")
            }
        }
    }

    /// `--demo-image <png>`: read a file instead of the screen (SPEC 15).
    func showImage(path: String, scale: CGFloat) {
        isActive = true
        model.reset()
        guard let image = ScreenCapturer.loadImage(at: path) else {
            AppLog.write("overlay: demo image not readable \(path)")
            fail("画像を読み込めませんでした")
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let factor = scale > 0 ? scale : 1
        let capture = ScreenCapturer.Capture(
            image: image,
            rect: CGRect(
                x: screen.frame.minX,
                y: ScreenGeometry.primaryHeight - screen.frame.maxY,
                width: CGFloat(image.width) / factor,
                height: CGFloat(image.height) / factor
            ),
            scale: factor,
            screen: screen
        )
        model.phase = .reading
        showWindow(on: screen)
        // Demo only: draw the picture in the window, so a screenshot shows the
        // translations over the text they cover. The window is shrunk to the
        // picture, anchored at the screen's top left, which is where the demo
        // places it — the block coordinates are unaffected because they are
        // measured from that same corner.
        model.backdrop = image
        model.backdropScale = factor
        let pictureSize = CGSize(width: CGFloat(image.width) / factor, height: CGFloat(image.height) / factor)
        model.windowWidth = pictureSize.width
        model.windowHeight = pictureSize.height
        window?.setFrame(
            CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - pictureSize.height,
                width: pictureSize.width,
                height: pictureSize.height
            ),
            display: true
        )
        let started = CFAbsoluteTimeGetCurrent()
        runStarted = started
        firstBlockLogged = false
        Task { [weak self] in
            do {
                try await self?.read(capture: capture, started: started)
            } catch {
                AppLog.write("overlay: demo read failed \(error)")
                self?.fail("画面を読み取れませんでした")
            }
        }
    }

    // MARK: reading

    private func read(capture: ScreenCapturer.Capture, started: CFAbsoluteTime) async throws {
        let language = AppSettings.shared.overlayLanguage
        // The whole-picture pass first, so the first blocks go up and start
        // translating while the tiled pass is still reading (M5.md 3.4).
        let wholeLines = try await ScreenOCR.wholeLines(in: capture.image, language: language)
        let blocks = OCRBlockBuilder.blocks(from: wholeLines)
        let readSeconds = CFAbsoluteTimeGetCurrent() - started
        AppLog.write(String(format: "overlay: read %d block(s) in %.3fs language=%@",
                            blocks.count, readSeconds, language))

        guard !blocks.isEmpty else {
            model.phase = .empty
            return
        }

        guard let pixels = PixelImage(cgImage: capture.image) else {
            throw ScreenCapturer.CaptureError.failed("画像を読み取れませんでした")
        }

        // The window's own size is the space the block coordinates are in; the
        // demo picture path makes it smaller than the screen.
        let windowSize = window?.frame.size ?? capture.screen.frame.size
        model.windowHeight = windowSize.height
        model.windowWidth = windowSize.width
        // `windowRect` measures from the screen's bottom left. The real window
        // covers the screen, but the demo window is shrunk to the picture at
        // the screen's top, so the frames are moved into the window's own space.
        let windowOffset = window.map {
            CGPoint(x: $0.frame.minX - capture.screen.frame.minX, y: $0.frame.minY - capture.screen.frame.minY)
        } ?? .zero
        // The page's usual line height, so a heading can be told from body text
        // when the weight is measured (`OverlayEmphasis`). It comes from the
        // picture's ink like the size itself, so the two are compared in the
        // same units and with the same precision (`TextInk`).
        let measured = blocks.map { measuredLineHeight(of: $0, pixels: pixels, fallback: $0.lineHeight) }
        let sortedHeights = measured.sorted()
        let medianLineHeight = sortedHeights.isEmpty ? 0 : sortedHeights[sortedHeights.count / 2]
        model.blocks = blocks.enumerated().map { index, block in
            overlayBlock(
                block,
                id: index,
                capture: capture,
                pixels: pixels,
                windowOffset: windowOffset,
                medianLineHeight: medianLineHeight,
                lineHeightPixels: measured[index],
                origin: "whole"
            )
        }
        model.phase = .showing
        updateHitRects()

        // The first block's translation is what the reader waits for; the
        // measurement of "reading to everything drawn" starts here.
        translator.start(blocks: blocks)

        // The tiled pass, which is what finds small text such as a sidebar's.
        // It runs after the first blocks are up. A block that overlaps one that
        // is already on the screen is not added: the block it would replace is
        // already being translated, and adding it would draw the same text
        // twice.
        let recovered = try await ScreenOCR.recoveredLines(in: capture.image, language: language)
        guard !recovered.isEmpty else { return }
        let merged = OCRBlockBuilder.blocks(
            from: OCRTiling.mergeRecovered(base: wholeLines, extra: recovered)
        )
        let additions = merged.filter { candidate in
            let frame = windowFrame(for: candidate, capture: capture, windowOffset: windowOffset)
            return !model.blocks.contains { $0.frame.intersects(frame) }
        }
        guard !additions.isEmpty else { return }
        let firstNewIndex = model.blocks.count
        for (offset, block) in additions.enumerated() {
            model.blocks.append(overlayBlock(
                block,
                id: firstNewIndex + offset,
                capture: capture,
                pixels: pixels,
                windowOffset: windowOffset,
                medianLineHeight: medianLineHeight,
                lineHeightPixels: measuredLineHeight(of: block, pixels: pixels, fallback: block.lineHeight),
                origin: "tiled"
            ))
        }
        updateHitRects()
        translator.extend(blocks: additions, indexes: Array(firstNewIndex..<model.blocks.count))
        AppLog.write("overlay: the tiled pass added \(additions.count) block(s)")
    }

    /// Where a recognised block lands in the overlay window's own coordinates.
    private func windowFrame(
        for block: OCRBlock,
        capture: ScreenCapturer.Capture,
        windowOffset: CGPoint
    ) -> CGRect {
        ScreenGeometry.windowRect(
            forPixelRect: block.rect,
            capture: capture.rect,
            scale: capture.scale,
            screen: capture.screen
        ).offsetBy(dx: -windowOffset.x, dy: -windowOffset.y)
    }

    /// One recognised block placed on the overlay, with its colours, its fitted
    /// font size and its weight.
    private func overlayBlock(
        _ block: OCRBlock,
        id: Int,
        capture: ScreenCapturer.Capture,
        pixels: PixelImage,
        windowOffset: CGPoint,
        medianLineHeight: CGFloat,
        lineHeightPixels: CGFloat,
        origin: String
    ) -> OverlayBlock {
        let frame = windowFrame(for: block, capture: capture, windowOffset: windowOffset)
        let background = OverlayBackground.color(in: pixels, around: block.rect)
        let textColor = OverlayBackground.textColor(in: pixels, block: block.rect, background: background)
        let pointsPerPixel = block.rect.height > 0 ? frame.height / block.rect.height : 1
        let boxLineHeight = block.lineHeight * pointsPerPixel
        let lineHeight = lineHeightPixels * pointsPerPixel
        let isBold = OverlayEmphasis.isBold(
            in: pixels,
            block: block.rect,
            text: block.text,
            lineHeight: lineHeightPixels,
            medianLineHeight: medianLineHeight
        )
        // The drawn size comes from the line height, so the reading that
        // produced it is recorded here: the whole-picture pass and a tile report
        // different boxes for the same line, which is what made equally sized
        // labels come out at different sizes (M5.md 8.2).
        AppLog.write(String(format: "overlay: block %d %@ frame=%.0fx%.0f lineHeight=%.1f (box %.1f) lines=%d bold=%@ %@",
                            id, origin, frame.width, frame.height, lineHeight, boxLineHeight,
                            block.lines.count, isBold ? "yes" : "no", String(block.text.prefix(40))))
        return OverlayBlock(
            id: id,
            source: block.text,
            frame: frame,
            lineHeight: lineHeight,
            availableHeight: max(frame.height, lineHeight),
            background: background,
            textColor: textColor,
            isBold: isBold,
            translation: nil,
            layout: nil
        )
    }

    /// One original line's height in **image pixels**, measured from the
    /// picture's ink (`TextInk`). `fallback` is Vision's box height, used when
    /// the ink cannot be read (an empty block, or text too small to measure).
    private func measuredLineHeight(of block: OCRBlock, pixels: PixelImage, fallback: CGFloat) -> CGFloat {
        let bands = block.lines.compactMap { TextInk.bandHeight(in: pixels, line: $0.rect) }
        guard let band = bands.sorted().dropFirst(bands.count / 2).first,
              let size = TextInk.fontSize(forBand: band)
        else { return fallback }
        return OverlayTextFit.lineHeightToFontSize * size
    }

    /// Sizes and stores one block's translation, which makes the view draw it.
    private func apply(_ translation: String, to index: Int) {
        guard index >= 0, index < model.blocks.count else { return }
        let frame = model.blocks[index].frame
        let minimumScale = CGFloat(AppSettings.shared.overlayMinScale)
        // The room the translation is fitted into is the block's box, but never
        // less than one line at the original size: Vision's box is the ink, and
        // a single line's ink is shorter than the line the translation needs,
        // which would shrink every one-line block to the floor (`TextInk`).
        let available = CGSize(
            width: frame.width,
            height: max(model.blocks[index].availableHeight, 1)
        )
        let layout = OverlayTextFit.layout(
            blockSize: available,
            originalFontSize: OverlayTextFit.originalFontSize(forLineHeight: model.blocks[index].lineHeight),
            minimumScale: minimumScale,
            measure: { width, size in
                TextMetrics.height(translation, width: width - 4, size: size, lineSpacing: 0)
            }
        )
        model.blocks[index].translation = translation
        model.blocks[index].layout = layout
        updateHitRects()
        AppLog.write(String(format: "overlay: block %d translation=%@", index, translation))
        // The fitted size, so a block that came out too small can be traced to
        // its input (the frame and the line height) rather than guessed at.
        AppLog.write(String(format: "overlay: block %d layout size=%.1fpt scale=%.2f width=%.0f height=%.0f overflow=%.1f",
                            index, layout.fontSize, layout.scale, frame.width, layout.textHeight, layout.overflow))
        if !firstBlockLogged {
            firstBlockLogged = true
            let elapsed = CFAbsoluteTimeGetCurrent() - runStarted
            AppLog.write(String(format: "overlay: first block drawn %.3fs after capture (block %d)",
                                elapsed, index))
        }
    }

    // MARK: window

    private func showWindow(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if let window {
            window.setFrame(screen.frame, display: true)
            model.windowHeight = screen.frame.height
            model.windowWidth = screen.frame.width
            return
        }
        model.windowHeight = screen.frame.height
        model.windowWidth = screen.frame.width

        let actions = OverlayActions(
            copyBlock: { [weak self] index in self?.copyBlock(index) },
            copyAll: { [weak self] in self?.copyAll() },
            close: { [weak self] in self?.finish(reason: "band close") },
            toggleSource: { [weak self] in
                guard let self else { return }
                self.model.showSource.toggle()
            },
            openSettings: { ScreenRecordingPermission.openSettings() }
        )
        let container = OverlayContainerView(model: model, actions: actions)
        container.frame = CGRect(origin: .zero, size: screen.frame.size)

        let window = OverlayWindow(
            contentRect: container.frame,
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
        window.ignoresMouseEvents = false
        window.contentView = container
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window

        setUpMonitors()
        AppLog.write("overlay: window on \(screen.localizedName) \(screen.frame)")
    }

    private func showPermissionNotice() {
        model.reset()
        model.phase = .needsPermission
        showWindow(on: OverlayPickerPlacement.screenForMouse())
        isActive = true
    }

    /// `--demo-surface overlay --demo-state permission` (SPEC 15, M4).
    func showPermissionDemo() {
        showPermissionNotice()
    }

    /// `--demo-surface overlay` with no image: the empty state (SPEC 13).
    func showEmptyDemo() {
        isActive = true
        model.reset()
        model.phase = .empty
        showWindow(on: OverlayPickerPlacement.screenForMouse())
    }

    private func fail(_ message: String) {
        model.reset()
        model.phase = .failed(message)
        showWindow(on: OverlayPickerPlacement.screenForMouse())
    }

    // MARK: dismissal (SPEC 4.6 の 5)

    private func setUpMonitors() {
        guard monitors.isEmpty else { return }

        // Scroll and a window being dragged are other apps' events, so a global
        // monitor sees them.
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissSoon(reason: "screen changed") }
            }
        )
        if let global { monitors.append(global) }

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: { [weak self] notification in
                let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    // Our own app is never activated by the overlay, but the
                    // check keeps a stray activation from closing it early.
                    guard activated?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                    self?.dismissSoon(reason: "front app changed")
                }
            }
        )
        workspaceObservers.append(observer)

        let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return consumed ? nil : event
            }
        )
        if let keys { monitors.append(keys) }

        let flags = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    self?.model.optionDown = event.modifierFlags.contains(.option)
                }
                return event
            }
        )
        if let flags { monitors.append(flags) }
    }

    private var workspaceObservers: [NSObjectProtocol] = []

    private func handleKey(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        switch event.keyCode {
        case 53: // esc
            finish(reason: "esc")
            return true
        case 8: // C
            if event.modifierFlags.contains(.command) {
                copyAll()
                return true
            }
        default:
            break
        }
        return false
    }

    /// A short delay, so a scroll that is really part of the reading does not
    /// take the overlay away the instant the wheel moves.
    private func dismissSoon(reason: String) {
        guard isActive, window != nil else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(reason: reason)
        }
    }

    // MARK: actions

    private func copyBlock(_ index: Int) {
        guard index >= 0, index < model.blocks.count else { return }
        let text = model.blocks[index].translation ?? ""
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.write("overlay: copied block \(index) (\(text.count) chars)")
        toast("コピーしました")
    }

    private func copyAll() {
        let text = model.blocks.compactMap(\.translation).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.write("overlay: copied all (\(model.blocks.count) blocks)")
        toast("コピーしました")
    }

    private func toast(_ message: String) {
        model.toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.model.toast == message else { return }
            self.model.toast = nil
        }
    }

    // MARK: teardown

    /// Puts everything away with a 200ms fade (SPEC 4.6 の 5).
    func finish(reason: String) {
        guard isActive || window != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        translator.cancel(notify: false)
        picker.hide()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []

        let closing = window
        window = nil
        isActive = false
        if let closing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                closing.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    closing.orderOut(nil)
                }
            }
        }
        model.phase = .idle
        AppLog.write("overlay: finished (\(reason))")
    }

    // MARK: helpers

    /// The rects the container lets clicks through in: every block that has a
    /// translation, plus the band.
    private func updateHitRects() {
        var rects = model.blocks.filter(\.hasTranslation).map { block in
            let overflow = block.layout?.overflow ?? 0
            return block.frame.insetBy(dx: -4, dy: -2).offsetBy(dx: 0, dy: -overflow)
        }
        if model.windowHeight > 0 {
            let band = OverlayModel.bandRect(windowSize: CGSize(width: model.windowWidth, height: model.windowHeight))
            rects.append(band.insetBy(dx: -8, dy: -8))
        }
        model.hitRects = rects
    }
}
