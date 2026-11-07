import AppKit
import SwiftUI
import YakuCore

/// State shared between the AppKit side (open/close, focus) and the SwiftUI
/// panel content. Translation state lives in `TranslationCoordinator`.
@MainActor
@Observable
final class PanelModel {
    var isOpen = false
    var isPinned = false
    /// Bumped whenever the panel opens, so the view can move focus to the field.
    var focusRequest = 0
    /// Height of the glass shape, in points (SPEC 4.2: 168...600).
    var contentHeight: CGFloat = PanelLayout.minHeight
    var translationContentHeight: CGFloat = 0
    /// Demo surfaces prefill the source field; focusing it would select the
    /// whole text, so they turn the automatic focus off.
    var autoFocusEnabled = true

    // MARK: drop (SPEC 4.2 の「ドロップ」)

    /// The whole content is replaced by the drop well while a file is over the
    /// panel or the menu bar icon.
    var isDropTarget = false
    var dropHover = false
    var dropMessage = "PDF をドロップして日本語に"
    /// Drives the one-off shake for a non-PDF drop.
    var dropShake: CGFloat = 0
}

/// Borderless, non-activating panel. It becomes key so it can take typing
/// without pulling the frontmost app out of the foreground.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Without this, AppKit pushes the window down below the menu bar and the
    /// panel would not sit where we put it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts the SwiftUI panel and only claims mouse events inside the glass
/// shape, so the rest of the (large, transparent) window passes clicks
/// through to whatever is underneath.
@MainActor
final class PanelContainerView: NSView {
    private let model: PanelModel
    private let hosting: NSHostingView<PanelRootView>
    private let glow: GlowPresenter
    /// Called with a file dropped on the panel (SPEC 4.2, 8.1).
    var onDrop: ((URL) -> Void)?
    /// Called when a dropped file is not a PDF, so the panel can shake.
    var onReject: (() -> Void)?

    init(
        model: PanelModel,
        coordinator: TranslationCoordinator,
        pdf: PDFQueue,
        onOpenPDF: @escaping () -> Void,
        onScreenTranslate: @escaping () -> Void
    ) {
        self.model = model
        self.hosting = NSHostingView(rootView: PanelRootView(
            model: model,
            coordinator: coordinator,
            pdf: pdf,
            onOpenPDF: onOpenPDF,
            onScreenTranslate: onScreenTranslate
        ))
        self.glow = GlowPresenter(
            cornerRadius: PanelLayout.cornerRadius,
            // Reading `contentHeight` here is what makes the presenter observe
            // it; the rect itself is in the container's coordinates.
            shapeRect: {
                PanelLayout.shapeRect(
                    in: CGRect(origin: .zero, size: PanelLayout.windowSize),
                    height: model.contentHeight,
                    flipped: false
                )
            },
            phase: { coordinator.panel.phase },
            isOpen: { model.isOpen }
        )
        super.init(frame: CGRect(origin: .zero, size: PanelLayout.windowSize))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)

        // Above the hosting view, but only inside the shape.
        glow.view.frame = shapeRect()
        addSubview(glow.view, positioned: .above, relativeTo: hosting)
        glow.start()

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelContainerView does not support NSCoder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return shapeRect().contains(local) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        model.dropHover = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        model.dropHover = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.dropHover = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURL(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard let first = urls.first else { return false }
        model.dropHover = false
        if first.pathExtension.lowercased() == "pdf" {
            model.isDropTarget = false
            onDrop?(first)
        } else {
            onReject?()
        }
        return true
    }

    private func hasFileURL(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
    }

    /// The glow sits in the same place as the glass shape, so the two stay
    /// aligned while the shape's height animates.
    override func layout() {
        super.layout()
        glow.view.frame = shapeRect()
    }

    private func shapeRect() -> CGRect {
        PanelLayout.shapeRect(in: bounds, height: model.contentHeight, flipped: isFlipped)
    }
}
