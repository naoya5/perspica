import AppKit
import SwiftUI
import YakuCore

/// Full-screen, borderless panel that draws the translations over the screen
/// (SPEC 4.6 の 3〜4). Like the panel and the HUD it never activates the app.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Claims mouse events only where a block or the band is, so the rest of the
/// screen keeps working.
@MainActor
final class OverlayContainerView: NSView {
    private let model: OverlayModel
    private let hosting: NSHostingView<OverlayRootView>

    init(model: OverlayModel, actions: OverlayActions) {
        self.model = model
        self.hosting = NSHostingView(rootView: OverlayRootView(model: model, actions: actions))
        super.init(frame: .zero)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverlayContainerView does not support NSCoder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard model.hitRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

/// What the overlay's band and blocks do.
struct OverlayActions {
    var copyBlock: (Int) -> Void = { _ in }
    var copyAll: () -> Void = {}
    var close: () -> Void = {}
    var toggleSource: () -> Void = {}
    var openSettings: () -> Void = {}
}

/// The overlay's content: one backing per translated block, the bottom band and
/// the empty / permission states (SPEC 4.6 の 3〜5).
struct OverlayRootView: View {
    @Bindable var model: OverlayModel
    var actions = OverlayActions()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .allowsHitTesting(false)

            // Demo only: the picture the blocks were read from, so a screenshot
            // shows whether the backing hides the original text. It sits at the
            // window's top left, which is where the demo places it.
            if let backdrop = model.backdrop {
                Image(decorative: backdrop, scale: model.backdropScale)
                    .allowsHitTesting(false)
            }

            ForEach(model.blocks) { block in
                if block.hasTranslation {
                    OverlayBlockView(block: block, windowHeight: model.windowHeight, showSource: showsSource)
                        .onTapGesture { actions.copyBlock(block.id) }
                }
            }

            if model.phase == .empty {
                message("訳せる文字が見つかりませんでした", systemImage: "text.viewfinder", button: nil)
            }
            if model.phase == .needsPermission {
                message(
                    "画面の文字を読むには、画面収録の許可が必要です",
                    systemImage: "rectangle.dashed.badge.record",
                    button: ("システム設定を開く", actions.openSettings)
                )
            }
            if case .failed(let text) = model.phase {
                message(text, systemImage: "exclamationmark.triangle.fill", button: nil)
            }

            if model.phase == .reading {
                readingIndicator
            }

            if let toast = model.toast {
                toastView(toast)
            }

            band
        }
        .ignoresSafeArea()
    }

    private var showsSource: Bool { model.optionDown || model.showSource }

    // MARK: blocks

    /// The band sits at the bottom centre (SPEC 4.6 の 4).
    private var band: some View {
        GeometryReader { proxy in
            let rect = OverlayModel.bandRect(windowSize: proxy.size)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    bandButton("原文を表示", systemImage: "text.alignleft", shortcut: "⌥", active: showsSource) {
                        actions.toggleSource()
                    }
                    bandButton("すべてコピー", systemImage: "doc.on.doc", shortcut: "⌘C", active: false) {
                        actions.copyAll()
                    }
                    bandButton("閉じる", systemImage: "xmark", shortcut: "Esc", active: false) {
                        actions.close()
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: proxy.size.height - rect.midY)
        }
        .allowsHitTesting(true)
    }

    private func bandButton(
        _ title: String,
        systemImage: String,
        shortcut: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
        .help("\(title)（\(shortcut)）")
        .accessibilityLabel(title)
    }

    /// Shown while the capture is being read, above the band.
    private var readingIndicator: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("文字を読み取っています…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 84)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// 「コピーしました」, just above the band (SPEC 4.6 の 4).
    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 84)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func message(
        _ text: String,
        systemImage: String,
        button: (String, () -> Void)?
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            if let button {
                Button(button.0) { button.1() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One translated block: the backing painted with the original's background,
/// the translation in the original's colour (SPEC 4.6 の 3).
private struct OverlayBlockView: View {
    let block: OverlayBlock
    let windowHeight: CGFloat
    let showSource: Bool

    @State private var visible = false

    private var text: String { showSource ? block.source : (block.translation ?? "") }
    private var fontSize: CGFloat {
        // Showing the source uses the original line height, so the reader can
        // compare the two; the translation uses the size that was fitted.
        showSource ? OverlayTextFit.originalFontSize(forLineHeight: block.lineHeight) : (block.layout?.fontSize ?? 12)
    }
    private var overflow: CGFloat { showSource ? 0 : (block.layout?.overflow ?? 0) }

    var body: some View {
        let top = windowHeight - block.frame.maxY
        let height = block.frame.height + overflow
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(block.textColor.color)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: block.frame.width, height: height, alignment: .topLeading)
            .clipped()
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(block.background.color, in: .rect(cornerRadius: 4, style: .continuous))
            .frame(width: block.frame.width + 4, height: height + 2, alignment: .topLeading)
            .offset(x: block.frame.minX - 2, y: top - 1)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.16)) { visible = true }
            }
            .accessibilityLabel(text)
    }
}

extension YakuCore.RGBColor {
    /// The SwiftUI colour for this value.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
