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
        HSplitView {
            sourcePane
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
    }

    // MARK: source

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManagerSectionLabel(text: "原文")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $coordinator.manager.sourceText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    // M5 (SPEC 15): an empty scrollbar track was showing down
                    // the right edge of the source field.
                    .scrollIndicators(.hidden)
                    .onChange(of: coordinator.manager.sourceText) { _, _ in
                        coordinator.managerTextChanged()
                    }
                if coordinator.manager.sourceText.isEmpty {
                    Text("訳したい文を入力")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                Text("⌘↩ で訳す")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let language = coordinator.manager.sourceLanguage {
                    Text("\(LanguageCatalog.name(for: language)) \(coordinator.manager.sourceText.count) 字")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 420)
    }

    // MARK: translation

    private var translationPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ManagerSectionLabel(text: "訳文")
                Spacer()
                if let elapsed = coordinator.manager.elapsed {
                    Text(String(format: "%.2f 秒 · %@ · この Mac の中で処理",
                                elapsed, coordinator.modelDisplayName))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                copyButton
            }
            translationBody
        }
        .padding(16)
        .frame(minWidth: 300)
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
        Button {
            model.copy(coordinator.manager.translation)
            withAnimation(.snappy(duration: 0.25)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.snappy(duration: 0.25)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
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
