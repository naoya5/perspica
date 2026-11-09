import SwiftUI
import YakuCore

/// 管理画面の「翻訳」(SPEC 4.4): two panes, the toolbar carrying the language,
/// the swap, the style and the translate button. The translation itself runs
/// through the same `TranslationCoordinator` the panel uses.
struct ManagerTranslateView: View {
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var model: ManagerModel

    @Namespace private var formNamespace
    @State private var reveal = TextRevealDriver()
    @State private var copied = false

    private static let translationFontSize: CGFloat = 17
    /// SPEC 4.4: 行間 1.5 倍.
    private static let translationLineSpacing: CGFloat = translationFontSize * 0.5

    var body: some View {
        // Two equal panes. Not HSplitView: inside NavigationSplitView it
        // ignored the floating sidebar's inset, squeezed the sidebar and pushed
        // the translation pane about 15 pt past the window's right edge
        // (M7 review).
        HStack(spacing: 0) {
            sourcePane
            Divider()
            translationPane
        }
        .navigationTitle("翻訳")
        .toolbar { toolbarContent }
        .onChange(of: coordinator.manager.translation) { _, new in
            reveal.update(count: new.count)
        }
        .onAppear {
            reveal.finish(to: coordinator.manager.translation.count)
        }
        .copiedMark(count: coordinator.manager.copyCount, copied: $copied)
    }

    // MARK: source

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.s) {
                ManagerSectionLabel(text: "原文")
                Spacer(minLength: 0)
                if let language = coordinator.manager.sourceLanguage {
                    Text("\(LanguageCatalog.name(for: language)) \(coordinator.manager.sourceText.count) 字")
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            // M7 5: the input is a card of its own, so 原文 and 訳文 read as two
            // faces of the same tool rather than one white sheet.
            //
            // A vertical TextField, the same control the panel's source field
            // uses (M1): TextEditor keeps an empty scrollbar track down its
            // right edge even with .scrollIndicators(.hidden) (M0/M2, still
            // visible in the M7 shots); the field does not.
            TextField("訳したい文を入力", text: $coordinator.manager.sourceText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(4...)
                .onChange(of: coordinator.manager.sourceText) { _, _ in
                    coordinator.managerTextChanged()
                }
                .accessibilityLabel("訳したい文")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .designCard(padding: Design.Space.m)
                .frame(maxHeight: .infinity)

            Text("⌘↩ で訳す")
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(Design.pagePadding)
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    // MARK: translation

    private var translationPane: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.s) {
                ManagerSectionLabel(text: "訳文")
                // The direction of the pair, in the header where it is read
                // first (M7 5).
                DesignLanguageDirection(
                    source: coordinator.manager.sourceLanguage,
                    target: coordinator.manager.targetLanguage
                )
                Spacer(minLength: Design.Space.s)
                copyButton
            }
            translationBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .designCard(padding: Design.Space.m)

            // Under the card, opposite the source pane's "⌘↩ で訳す": in the
            // header it pushed the copy button off the edge and wrapped onto
            // two lines at the default width (M7 review).
            Text(elapsedSummary)
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
        }
        .padding(Design.pagePadding)
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    /// Always one line of text, so the card keeps the same height before and
    /// after the first translation.
    private var elapsedSummary: String {
        guard let elapsed = coordinator.manager.elapsed else { return "この Mac の中で処理" }
        return String(format: "%.2f 秒 · %@ · この Mac の中で処理", elapsed, coordinator.modelDisplayName)
    }

    @ViewBuilder
    private var translationBody: some View {
        switch coordinator.manager.phase {
        case .empty:
            Text("訳文がここに出ます")
                .font(.system(size: Self.translationFontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .preparing:
            Text("準備しています…")
                .font(.system(size: Self.translationFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .translating, .done:
            ScrollView {
                Text(coordinator.manager.translation)
                    .font(.system(size: Self.translationFontSize))
                    .lineSpacing(Self.translationLineSpacing)
                    .textRenderer(FadeInTextRenderer(revealed: reveal.revealed))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
            .overlay {
                ProcessingGlowOverlay(
                    active: coordinator.manager.phase == .translating
                        || coordinator.manager.phase == .preparing,
                    cornerRadius: 10,
                    cycleSeconds: 2.4
                )
                .allowsHitTesting(false)
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(failure.message)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("もう一度") { coordinator.retryManager() }
                    if failure.showsLogButton {
                        Button("ログを見る") { NSWorkspace.shared.open(AppPaths.logsDirectory) }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var copyButton: some View {
        // M7 5: 訳す is the one prominent action; the copy is a quiet, labelled
        // secondary button, so the two are never mistaken for each other.
        Button {
            coordinator.copyTranslation(on: .manager)
        } label: {
            Label(copied ? "コピーしました" : "コピー",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: Design.Font.caption))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(coordinator.manager.translation.isEmpty)
        .help("訳文をコピー")
        .accessibilityLabel("訳文をコピー")
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            languageMenu
            Button {
                coordinator.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("言語を入れ替える（⌘D）")
            .accessibilityLabel("言語を入れ替える")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if coordinator.manager.targetLanguage == "ja" {
                formToggle
            }
            Button("訳す") {
                coordinator.translateManager()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("訳す（⌘↩）")
        }
    }

    private var languageMenu: some View {
        Menu {
            Button("自動（原文を判定）") { coordinator.clearManualPair() }
            Section("よく使う") {
                ForEach(LanguageCatalog.frequent) { language in
                    Button(language.japaneseName) {
                        coordinator.setManualTarget(language.code, forSource: coordinator.manager.sourceLanguage)
                    }
                }
            }
            Section("その他") {
                ForEach(LanguageCatalog.others) { language in
                    Button(language.japaneseName) {
                        coordinator.setManualTarget(language.code, forSource: coordinator.manager.sourceLanguage)
                    }
                }
            }
        } label: {
            Text(languageMenuTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("訳す言語を選ぶ")
    }

    private var languageMenuTitle: String {
        var title = LanguageCatalog.automaticName
        if let code = coordinator.manager.sourceLanguage {
            title += "（\(LanguageCatalog.name(for: code))）"
        }
        title += " → \(LanguageCatalog.name(for: coordinator.manager.targetLanguage))"
        return title
    }

    private var formToggle: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                formSegment("である", value: .plain)
                formSegment("です・ます", value: .polite)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文体")
    }

    private func formSegment(_ title: String, value: TranslationForm) -> some View {
        let selected = coordinator.form == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) { coordinator.setForm(value) }
        } label: {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(value.rawValue, in: formNamespace)
        .help("\(title) で訳す")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
