import AppKit
import SwiftUI
import YakuCore

/// What the HUD is showing when it is not showing a translation (SPEC 4.3).
enum HUDNotice: Equatable {
    case noSelection
    case permissionNeeded

    var message: String {
        switch self {
        case .noSelection: "文を選んでから ⌃⌥J"
        case .permissionNeeded: "選んだ文を読むには、アクセシビリティの許可が必要です"
        }
    }
}

/// UI-only state of the HUD window. The translation itself is
/// `TranslationCoordinator.hud`.
@MainActor
@Observable
final class HUDModel {
    var isVisible = false
    var notice: HUDNotice?
    var canReplace = false
    var contentHeight: CGFloat = HUDLayout.minimumTextHeight + HUDLayout.footerHeight + HUDLayout.innerPadding * 2
    var textContentHeight: CGFloat = 0
}

/// Callbacks the HUD view needs. Closures rather than a reference to the
/// controller, so the window and the view do not form a retain cycle.
struct HUDActions {
    var replace: () -> Void = {}
    var openInPanel: () -> Void = {}
}

/// The HUD (SPEC 4.3): the same kind of window as the panel, so the frontmost
/// app stays frontmost, sized to its content and capped at 360 points.
struct HUDView: View {
    @Bindable var model: HUDModel
    @Bindable var coordinator: TranslationCoordinator
    var actions = HUDActions()

    @State private var copied = false
    @State private var reveal = TextRevealDriver()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            shape
                .frame(width: HUDLayout.width, height: model.contentHeight, alignment: .top)
                .offset(x: HUDLayout.shadowMargin, y: 0)
                .opacity(model.isVisible ? 1 : 0)
                .animation(model.isVisible ? openAnimation : closeAnimation, value: model.isVisible)
        }
        .frame(
            width: HUDLayout.windowWidth,
            height: HUDLayout.windowHeight,
            alignment: .topLeading
        )
        .onAppear {
            model.contentHeight = desiredHeight
            reveal.finish(to: coordinator.hud.translation.count)
        }
        .onChange(of: desiredHeight) { _, new in
            withAnimation(.easeOut(duration: 0.16)) { model.contentHeight = new }
        }
        .onChange(of: coordinator.hud.translation) { _, new in
            reveal.update(count: new.count)
        }
        .copiedMark(count: coordinator.hud.copyCount, copied: $copied)
    }

    private var reduceMotion: Bool {
        AppearanceOverrides.reduceMotion
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.80)
    }

    private var closeAnimation: Animation { .easeInOut(duration: 0.16) }

    private var shape: some View {
        content
            .frame(width: HUDLayout.width, height: model.contentHeight, alignment: .top)
            .yakuGlass(in: .rect(cornerRadius: HUDLayout.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    // MARK: height

    private var desiredHeight: CGFloat {
        let height: CGFloat
        if model.notice != nil {
            height = 24 + HUDLayout.innerPadding * 2
        } else {
            switch coordinator.hud.phase {
            case .failed:
                height = 64 + HUDLayout.footerHeight + HUDLayout.innerPadding * 2
            default:
                let wanted = model.textContentHeight + HUDLayout.footerHeight + HUDLayout.innerPadding * 2
                height = min(
                    max(wanted, HUDLayout.minimumTextHeight + HUDLayout.footerHeight + HUDLayout.innerPadding * 2),
                    HUDLayout.maxHeight
                )
            }
        }
        return min(max(height, 20), HUDLayout.maxHeight)
    }

    // MARK: content

    private var content: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                noticeView(notice)
            } else {
                textArea
                footer
            }
        }
        .frame(width: HUDLayout.width, height: model.contentHeight, alignment: .top)
    }

    private func noticeView(_ notice: HUDNotice) -> some View {
        HStack(spacing: 8) {
            Text(notice.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if notice == .permissionNeeded {
                Button("システム設定を開く") { AccessibilityPermission.openSettings() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUDLayout.innerPadding)
        .padding(.vertical, HUDLayout.innerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The notice replaces the whole HUD, so VoiceOver gets one element
        // named after it rather than a stray sentence (SPEC 18).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.message)
    }

    @ViewBuilder
    private var textArea: some View {
        Group {
            switch coordinator.hud.phase {
            case .empty:
                Color.clear
            case .preparing:
                Text("準備しています…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("訳文、準備しています")
            case .failed(let failure):
                failureView(failure)
            case .translating, .done:
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        Text(displayText)
                            .font(.system(size: HUDLayout.fontSize))
                            .lineSpacing(HUDLayout.lineSpacing)
                            .textRenderer(FadeInTextRenderer(revealed: reveal.revealed))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("translation")
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                model.textContentHeight = height
                            }
                    }
                    .defaultScrollAnchor(.top)
                    .scrollIndicators(.automatic)
                    // Names the text without replacing it: a label on the Text
                    // itself would be read instead of the translation.
                    .accessibilityLabel(coordinator.optionDown ? "原文" : "訳文")
                    .onChange(of: coordinator.hud.scrollReset) { _, _ in
                        proxy.scrollTo("translation", anchor: .top)
                    }
                }
            }
        }
        .padding(.horizontal, HUDLayout.innerPadding)
        .padding(.top, HUDLayout.innerPadding)
        .frame(
            height: max(model.contentHeight - HUDLayout.footerHeight - HUDLayout.innerPadding, 0),
            alignment: .top
        )
    }

    private var displayText: String {
        coordinator.optionDown ? coordinator.hud.sourceText : coordinator.hud.translation
    }

    private func failureView(_ failure: TranslationCoordinator.TranslationFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Button("もう一度") { coordinator.retryHUD() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("訳文、エラー、\(failure.message)")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(LanguageCatalog.name(for: coordinator.hud.sourceLanguage)) → \(LanguageCatalog.name(for: coordinator.hud.targetLanguage))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "\(LanguageCatalog.name(for: coordinator.hud.sourceLanguage)) から "
                    + "\(LanguageCatalog.name(for: coordinator.hud.targetLanguage)) へ"
                )
            Spacer(minLength: 4)

            if model.canReplace {
                footerButton("arrow.turn.down.left", help: "選択した文を置き換える（⌘↩）", label: "置き換える") {
                    actions.replace()
                }
            }
            footerButton(copied ? "checkmark" : "doc.on.doc", help: "訳文をコピー（⌘C）", label: "コピー") {
                coordinator.copyTranslation(on: .hud)
            }
            footerButton("macwindow", help: "パネルで開く（⌘O）", label: "パネルで開く") {
                actions.openInPanel()
            }
        }
        .padding(.horizontal, HUDLayout.innerPadding)
        .frame(height: HUDLayout.footerHeight)
    }

    private func footerButton(
        _ systemName: String,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}
