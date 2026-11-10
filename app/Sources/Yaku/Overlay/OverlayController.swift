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
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var captureRight: CGFloat = 0
    private var translationAllowed = true
    private var readingComplete = false
    private var retryBlocks: [OCRBlock] = []
    /// The toast's 1.2-second wait. A new toast replaces it, so a second copy
    /// keeps 「コピーしました」 up for its own 1.2 seconds.
    private var toastTask: Task<Void, Never>?
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
            await self?.apply(translation, to: index)
        }
        translator.onFinished = { [weak self] completed in
            guard completed else { return }
            self?.finishTranslations()
        }
    }

    private func finishTranslations() {
        guard readingComplete, isActive, translationAllowed, !translator.isRunning,
              model.phase == .showing else { return }
        // Keep the first-pass blocks until tiled recovery finishes, even when
        // all first-pass translations were skipped or failed.
        if model.translatedCount == 0 {
            model.translationFailure = translator.failure
            model.hitRects = []
            if let failure = translator.failure {
                model.phase = .failed(failure.message)
            } else {
                model.blocks = []
                model.phase = translator.skippedCount > 0 ? .empty : .failed("翻訳できませんでした")
            }
            AppLog.write("overlay: no translated blocks after both reading passes")
            return
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - runStarted
        AppLog.write(String(format: "overlay: all %d block(s) drawn %.3fs after capture",
                            model.translatedCount, elapsed))
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
        retryBlocks = []
        model.phase = .picking
        picker.show()
    }

    /// `--demo-surface overlay-picker`: the picker on its own (SPEC 15).
    func showPickerDemo() {
        isActive = true
        model.reset()
        retryBlocks = []
        model.phase = .picking
        picker.show()
    }

    /// SPEC 7.3: a dialogue request takes the engine ahead of the screen
    /// overlay, so its translations stop. The overlay itself stays up with
    /// whatever has already been drawn.
    func yieldToDialogue() {
        guard isActive else { return }
        translationAllowed = false
        translator.cancel(notify: false)
        AppLog.write("overlay: gave way to a dialogue request")
    }

    // MARK: capture

    private func startCapture(rect: CGRect) {
        guard isActive else { return }
        captureTask?.cancel()
        translator.cancel(notify: false)
        model.reset()
        captureGeneration += 1
        let generation = captureGeneration
        translationAllowed = true
        model.phase = .reading
        showWindow(on: ScreenGeometry.screen(containingCGRect: rect))
        let started = CFAbsoluteTimeGetCurrent()
        runStarted = started
        firstBlockLogged = false

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await ScreenCapturer.capture(rect: rect)
                guard !Task.isCancelled, generation == self.captureGeneration else { return }
                try await self.read(capture: capture, started: started)
            } catch {
                guard !Task.isCancelled, generation == self.captureGeneration else { return }
                AppLog.write("overlay: capture failed \(error)")
                self.fail(ScreenRecordingPermission.isGranted
                    ? "画面を読み取れませんでした: \(error.localizedDescription)"
                    : "画面の文字を読むには、画面収録の許可が必要です")
            }
        }
    }

    /// `--demo-image <png>`: read a file instead of the screen (SPEC 15).
    func showImage(path: String, scale: CGFloat) {
        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()
        translator.cancel(notify: false)
        translationAllowed = true
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
        captureTask = Task { [weak self] in
            do {
                try await self?.read(capture: capture, started: started)
            } catch {
                guard !Task.isCancelled, generation == self?.captureGeneration else { return }
                AppLog.write("overlay: demo read failed \(error)")
                self?.fail("画面を読み取れませんでした")
            }
        }
    }

    // MARK: reading

    private func read(capture: ScreenCapturer.Capture, started: CFAbsoluteTime) async throws {
        readingComplete = false
        let generation = captureGeneration
        defer {
            if !Task.isCancelled, generation == captureGeneration, isActive {
                readingComplete = true
                finishTranslations()
            }
        }
        let language = AppSettings.shared.overlayLanguage
        // The whole-picture pass first, so the first blocks go up and start
        // translating while the tiled pass is still reading.
        let visionStarted = CFAbsoluteTimeGetCurrent()
        let wholePass = try await ScreenOCR.wholeLines(in: capture.image, language: language)
        let neededEarlyRecovery = wholePass.isEmpty
        let wholeLines = neededEarlyRecovery
            ? try await ScreenOCR.recoveredLines(in: capture.image, language: language)
            : wholePass
        try Task.checkCancellation()
        let visionSeconds = CFAbsoluteTimeGetCurrent() - visionStarted

        let image = capture.image
        guard let pixels = try await Self.background({
            PixelImage(cgImage: image)
        }) else {
            throw ScreenCapturer.CaptureError.failed("画像を読み取れませんでした")
        }
        // One reading per line, shared by the split rule and by the size the
        // translation is drawn at, so the picture is scanned once per line
        // rather than once per use.
        let pointsPerPixel = 1 / max(1, capture.scale)
        let inkStarted = CFAbsoluteTimeGetCurrent()
        var readings = try await Self.background {
            Self.measure(wholeLines, pixels: pixels, pointsPerPixel: pointsPerPixel)
        }
        try Task.checkCancellation()
        let inkSeconds = CFAbsoluteTimeGetCurrent() - inkStarted
        let initialReadings = readings
        let sizeOf: (OCRLine) -> CGFloat? = { initialReadings[$0.rect]?.size }

        let groupStarted = CFAbsoluteTimeGetCurrent()
        let blocks = OCRBlockBuilder.blocks(from: wholeLines, sizeOf: sizeOf)
        let groupSeconds = CFAbsoluteTimeGetCurrent() - groupStarted
        let readSeconds = CFAbsoluteTimeGetCurrent() - started
        AppLog.write(String(format: "overlay: read %d line(s) → %d block(s) in %.3fs "
                            + "(vision %.3f, ink %.3f, group %.3f) language=%@ %@",
                            wholeLines.count, blocks.count, readSeconds, visionSeconds, inkSeconds,
                            groupSeconds, language, TextInk.summary(readings.values.map(\.source))))

        guard !blocks.isEmpty else {
            model.phase = .empty
            return
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
        captureRight = ScreenGeometry.windowRect(
            forPixelRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            capture: capture.rect, scale: capture.scale, screen: capture.screen
        ).maxX - windowOffset.x
        // The page's usual line height, so a heading can be told from body text
        // when the weight is measured (`OverlayEmphasis`). It comes from the
        // picture's ink like the size itself, so the two are compared in the
        // same units and with the same precision (`TextInk`).
        let measured = blocks.map { Self.measuredLineHeight(of: $0, readings: readings, fallback: $0.lineHeight) }
        let sortedHeights = measured.map(\.pixels).sorted()
        let medianLineHeight = sortedHeights.isEmpty ? 0 : sortedHeights[sortedHeights.count / 2]
        let buildStarted = CFAbsoluteTimeGetCurrent()
        let appearances = try await Self.background {
            blocks.enumerated().map { index, block in
                Self.appearance(block, pixels: pixels, lineHeight: measured[index].pixels,
                                medianLineHeight: medianLineHeight)
            }
        }
        try Task.checkCancellation()
        model.blocks = blocks.enumerated().map { index, block in
            overlayBlock(
                block,
                id: index,
                capture: capture,
                appearance: appearances[index],
                windowOffset: windowOffset,
                medianLineHeight: medianLineHeight,
                lineHeightPixels: measured[index].pixels,
                lineHeightSource: measured[index].source,
                origin: "whole"
            )
        }
        let buildSeconds = CFAbsoluteTimeGetCurrent() - buildStarted
        AppLog.write(String(format: "overlay: built %d block(s) in %.3fs (colours and weight)",
                            blocks.count, buildSeconds))
        model.phase = .showing
        updateWidenLimits()
        updateHitRects()

        // The first block's translation is what the reader waits for; the
        // measurement of "reading to everything drawn" starts here.
        retryBlocks = blocks
        if translationAllowed { translator.start(blocks: blocks) }
        guard !neededEarlyRecovery else { return }

        // The tiled pass, which is what finds small text such as a sidebar's.
        // It runs after the first blocks are up. A block that overlaps one that
        // is already on the screen is not added: the block it would replace is
        // already being translated, and adding it would draw the same text
        // twice.
        let tiledStarted = CFAbsoluteTimeGetCurrent()
        let recovered = try await ScreenOCR.recoveredLines(in: capture.image, language: language)
        try Task.checkCancellation()
        guard !recovered.isEmpty else { return }
        let extraReadings = try await Self.background {
            Self.measure(recovered, pixels: pixels, pointsPerPixel: pointsPerPixel)
        }
        try Task.checkCancellation()
        readings.merge(extraReadings) { existing, _ in existing }
        let allReadings = readings
        let merged = OCRBlockBuilder.blocks(
            from: OCRTiling.mergeRecovered(base: wholeLines, extra: recovered),
            sizeOf: { allReadings[$0.rect]?.size }
        )
        let additions = merged.filter { candidate in
            let frame = windowFrame(for: candidate, capture: capture, windowOffset: windowOffset)
            return !model.blocks.contains { $0.frame.intersects(frame) }
        }
        guard !additions.isEmpty else { return }
        let addedReadings = additions.map { Self.measuredLineHeight(of: $0, readings: readings, fallback: $0.lineHeight) }
        let addedAppearances = try await Self.background {
            additions.enumerated().map { index, block in
                Self.appearance(block, pixels: pixels, lineHeight: addedReadings[index].pixels,
                                medianLineHeight: medianLineHeight)
            }
        }
        try Task.checkCancellation()
        let firstNewIndex = model.blocks.count
        for (offset, block) in additions.enumerated() {
            let reading = addedReadings[offset]
            model.blocks.append(overlayBlock(
                block,
                id: firstNewIndex + offset,
                capture: capture,
                appearance: addedAppearances[offset],
                windowOffset: windowOffset,
                medianLineHeight: medianLineHeight,
                lineHeightPixels: reading.pixels,
                lineHeightSource: reading.source,
                origin: "tiled"
            ))
        }
        updateWidenLimits()
        updateHitRects()
        // A newly recovered neighbor can narrow an already translated block.
        for block in model.blocks where block.hasTranslation {
            try Task.checkCancellation()
            await apply(block.translation ?? "", to: block.id)
        }
        if translationAllowed {
            retryBlocks.append(contentsOf: additions)
            translator.extend(blocks: additions, indexes: Array(firstNewIndex..<model.blocks.count))
        }
        AppLog.write(String(format: "overlay: the tiled pass added %d block(s) in %.3fs",
                            additions.count, CFAbsoluteTimeGetCurrent() - tiledStarted))
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
    private struct Appearance: Sendable {
        let background: RGBColor
        let textColor: RGBColor
        let isBold: Bool
    }

    nonisolated private static func appearance(
        _ block: OCRBlock, pixels: PixelImage, lineHeight: CGFloat, medianLineHeight: CGFloat
    ) -> Appearance {
        let background = OverlayBackground.color(in: pixels, around: block.rect)
        return Appearance(
            background: background,
            textColor: OverlayBackground.textColor(in: pixels, block: block.rect, background: background),
            isBold: OverlayEmphasis.isBold(in: pixels, block: block.rect, text: block.text,
                                         lineHeight: lineHeight, medianLineHeight: medianLineHeight)
        )
    }

    private func overlayBlock(
        _ block: OCRBlock,
        id: Int,
        capture: ScreenCapturer.Capture,
        appearance: Appearance,
        windowOffset: CGPoint,
        medianLineHeight: CGFloat,
        lineHeightPixels: CGFloat,
        lineHeightSource: TextInk.Reading.Source,
        origin: String
    ) -> OverlayBlock {
        let frame = windowFrame(for: block, capture: capture, windowOffset: windowOffset)
        let pointsPerPixel = block.rect.height > 0 ? frame.height / block.rect.height : 1
        let boxLineHeight = block.lineHeight * pointsPerPixel
        let lineHeight = lineHeightPixels * pointsPerPixel
        let isBold = appearance.isBold
        // The drawn size comes from the line height, so the reading that
        // produced it is recorded here: the whole-picture pass and a tile report
        // different boxes for the same line, which is what made equally sized
        // labels come out at different sizes. `from` says whether
        // the height was measured from the ink or came from Vision's box, which
        // is not comparable with a measured one.
        AppLog.write(String(format: "overlay: block %d %@ frame=%.0fx%.0f lineHeight=%.1f (box %.1f, from %@) lines=%d bold=%@ chars=%d",
                            id, origin, frame.width, frame.height, lineHeight, boxLineHeight,
                            lineHeightSource.rawValue,
                            block.lines.count, isBold ? "yes" : "no", block.text.count))
        AppLog.content("overlay: block \(id) text=\(block.text.prefix(40))")
        return OverlayBlock(
            id: id,
            source: block.text,
            frame: frame,
            lineHeight: lineHeight,
            availableHeight: max(frame.height, lineHeight),
            lineCount: block.lines.count,
            background: appearance.background,
            textColor: appearance.textColor,
            isBold: isBold,
            translation: nil,
            layout: nil
        )
    }

    /// How far right each one-line block may grow before it would reach the
    /// next block on the same line (SPEC 4.6 の 3). Called after every batch of
    /// blocks, because a block the tiled pass adds can sit beside one that is
    /// already up.
    private func updateWidenLimits() {
        for index in model.blocks.indices {
            let frame = model.blocks[index].frame
            guard model.blocks[index].lineCount == 1, frame.width > 0 else {
                model.blocks[index].widenTo = nil
                continue
            }
            // The nearest block sharing this block's rows and starting to its
            // right, or the edge of what was captured when there is none.
            model.blocks[index].widenTo = OverlayGeometry.wideningWidth(
                frame: frame, neighbors: model.blocks.filter { $0.id != index }.map(\.frame),
                captureRight: captureRight, gap: OverlayModel.widenGap
            )
        }
    }

    /// One size reading per recognised line, keyed by the line's box.
    ///
    /// The size the overlay draws at and the size the split rule compares must
    /// come from the same reading, or a line the ink cannot be measured from
    /// would be split on Vision's box height in one place and drawn from it in
    /// another. The picture is scanned once per line here.
    nonisolated private static func measure(
        _ lines: [OCRLine],
        pixels: PixelImage,
        pointsPerPixel: CGFloat
    ) -> [CGRect: TextInk.Reading] {
        var readings: [CGRect: TextInk.Reading] = [:]
        readings.reserveCapacity(lines.count)
        for line in lines where readings[line.rect] == nil {
            guard !Task.isCancelled else { break }
            readings[line.rect] = TextInk.reading(
                in: pixels, line: line.rect, text: line.text, pointsPerPixel: pointsPerPixel
            )
        }
        return readings
    }

    /// A block's line height in image pixels, with the reading it came from.
    private struct LineHeight: Sendable {
        let pixels: CGFloat
        let source: TextInk.Reading.Source
    }

    /// One block's line height in **image pixels**, with the reading it came
    /// from. `fallback` is Vision's own box height, used only when the ink
    /// cannot be read at all.
    ///
    /// The width of the ink against the recognised text's width is preferred: it
    /// reads every script the same, where the ink band follows the x-height and
    /// so reads Japanese text far larger than English text of the same size
    /// (`TextInk.fontSize(in:line:text:)`). The band is the fallback and
    /// Vision's box the last resort — a box value is not comparable with a
    /// measured one, which is why the source travels with it and is logged.
    nonisolated private static func measuredLineHeight(
        of block: OCRBlock,
        readings: [CGRect: TextInk.Reading],
        fallback: CGFloat
    ) -> LineHeight {
        let found = block.lines.compactMap { readings[$0.rect] }
        // The upper median: taking the lower one would drag a block that holds
        // both a title and its description down to the smaller of the two.
        let ordered = found.sorted { first, second in
            (first.size ?? -1) < (second.size ?? -1)
        }
        let chosen = ordered.dropFirst(ordered.count / 2).first ?? ordered.last
        guard let size = chosen?.size else {
            return LineHeight(pixels: fallback, source: .box)
        }
        return LineHeight(pixels: OverlayTextFit.lineHeightToFontSize * size, source: chosen?.source ?? .box)
    }

    /// Sizes and stores one block's translation, which makes the view draw it.
    private func apply(_ translation: String, to index: Int) async {
        guard index >= 0, index < model.blocks.count else { return }
        let generation = captureGeneration
        let block = model.blocks[index]
        let frame = block.frame
        let minimumScale = CGFloat(AppSettings.shared.overlayMinScale)
        // The room the translation is fitted into is the block's box, but never
        // less than one line at the original size: Vision's box is the ink, and
        // a single line's ink is shorter than the line the translation needs,
        // which would shrink every one-line block to the floor (`TextInk`).
        let available = CGSize(
            width: frame.width,
            height: max(block.availableHeight, 1)
        )
        guard let layout = try? await Self.background({
            OverlayTextFit.layout(
                text: translation,
                blockSize: available,
                originalFontSize: OverlayTextFit.originalFontSize(forLineHeight: block.lineHeight),
                minimumScale: minimumScale,
                widenTo: block.widenTo,
                measure: { text, width, size in
                    TextMetrics.height(text, width: width, size: size, lineSpacing: 0,
                                       weight: block.isBold ? .bold : .regular)
                }
            )
        }), !Task.isCancelled, generation == captureGeneration, isActive,
              index < model.blocks.count else { return }
        if model.blocks[index].widenTo != block.widenTo {
            await apply(translation, to: index)
            return
        }
        model.blocks[index].translation = translation
        model.blocks[index].layout = layout
        updateHitRects()
        AppLog.write("overlay: block \(index) translated (\(translation.count) chars)")
        AppLog.content("overlay: block \(index) translation=\(translation)")
        // The fitted size, so a block that came out too small can be traced to
        // its input (the frame and the line height) rather than guessed at.
        AppLog.write(String(format: "overlay: block %d layout size=%.1fpt scale=%.2f width=%.0f (box %.0f) height=%.0f overflow=%.1f",
                            index, layout.fontSize, layout.scale, layout.width, frame.width,
                            layout.textHeight, layout.overflow))
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
            updateHitRects()
            return
        }
        model.windowHeight = screen.frame.height
        model.windowWidth = screen.frame.width
        updateHitRects()

        let actions = OverlayActions(
            copyBlock: { [weak self] index in self?.copyBlock(index) },
            copyAll: { [weak self] in self?.copyAll() },
            close: { [weak self] in self?.finish(reason: "band close") },
            toggleSource: { [weak self] in
                guard let self else { return }
                self.model.showSource.toggle()
            },
            openSettings: { ScreenRecordingPermission.openSettings() },
            openModels: { [weak self] in
                self?.finish(reason: "open models")
                WindowBridge.shared.openManager(page: .models)
            },
            openLogs: { [weak self] in
                self?.finish(reason: "open logs")
                NSWorkspace.shared.open(AppPaths.logsDirectory)
            },
            retry: { [weak self] in self?.retryTranslation() }
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

    /// `--demo-surface overlay --demo-state permission` (SPEC 15).
    func showPermissionDemo() {
        showPermissionNotice()
    }

    /// Foreground refresh never prompts or captures a screen on its own.
    func refreshPermissions(screenRecordingGranted: Bool) {
        if screenRecordingGranted {
            if model.phase == .needsPermission {
                finish(reason: "screen recording permission granted")
            }
            return
        }
        guard isActive, model.phase != .needsPermission else { return }
        finish(reason: "screen recording permission revoked")
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
        let localChanges = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissSoon(reason: "screen changed") }
            return event
        }
        if let localChanges { monitors.append(localChanges) }

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
        guard isActive, window != nil, dismissTask == nil else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(reason: reason)
        }
    }

    // MARK: actions

    private func retryTranslation() {
        guard isActive, !retryBlocks.isEmpty else { return }
        model.translationFailure = nil
        model.phase = .showing
        translationAllowed = true
        readingComplete = true
        updateHitRects()
        translator.start(blocks: retryBlocks)
    }

    private func copyBlock(_ index: Int) {
        guard index >= 0, index < model.blocks.count else { return }
        let text = model.blocks[index].translation ?? ""
        guard Clipboard.copy(text) else { return }
        AppLog.write("overlay: copied block \(index) (\(text.count) chars)")
        toast("コピーしました")
    }

    private func copyAll() {
        let text = model.blocks.compactMap(\.translation).filter { !$0.isEmpty }.joined(separator: "\n")
        guard Clipboard.copy(text) else { return }
        AppLog.write("overlay: copied all (\(model.blocks.count) blocks)")
        toast("コピーしました")
    }

    private func toast(_ message: String) {
        model.toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            self?.model.toast = nil
        }
    }

    // MARK: teardown

    /// Puts everything away with a 200ms fade (SPEC 4.6 の 5).
    func finish(reason: String) {
        guard isActive || window != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        translationAllowed = false
        retryBlocks = []
        toastTask?.cancel()
        toastTask = nil
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

    /// Expensive image and CoreText work never runs on the UI executor.
    /// Detached work still stops when its capture/translation is cancelled.
    nonisolated private static func background<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return operation()
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    /// The rects the container lets clicks through in: every block that has a
    /// translation, plus the band.
    private func updateHitRects() {
        var rects = model.blocks.filter(\.hasTranslation).map { block in
            let width = block.layout?.width ?? block.frame.width
            return OverlayGeometry.hitRect(
                frame: block.frame, width: width,
                height: max(block.lineHeight, block.layout?.textHeight ?? 0)
            )
        }
        if model.windowHeight > 0 {
            let band = OverlayModel.bandRect(windowSize: CGSize(width: model.windowWidth, height: model.windowHeight))
            rects.append(band.insetBy(dx: -8, dy: -8))
        }
        model.hitRects = rects
    }
}
