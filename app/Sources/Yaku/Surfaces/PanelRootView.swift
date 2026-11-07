import AppKit
import SwiftUI
import YakuCore

/// The menu bar panel (SPEC 4.2).
///
/// The window never resizes; the glass shape inside it follows the content
/// between 168 and 600 points. The two measured heights the shape needs (the
/// source field and the translation text) are reported back through
/// `onGeometryChange`, so the height is exact rather than estimated.
struct PanelRootView: View {
    @Bindable var model: PanelModel
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var pdf: PDFQueue
    var onOpenPDF: () -> Void
    var onScreenTranslate: () -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @FocusState private var sourceFocused: Bool
    @Namespace private var formNamespace
    @State private var copied = false
    @State private var reveal = TextRevealDriver()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            shape
                .frame(width: PanelLayout.width, height: model.contentHeight, alignment: .top)
                .offset(x: PanelLayout.shadowMargin, y: 0)
                .scaleEffect(scale, anchor: .top)
                .opacity(model.isOpen ? 1 : 0)
                .animation(model.isOpen ? openAnimation : closeAnimation, value: model.isOpen)
                .modifier(PanelShakeEffect(shakes: model.dropShake))
        }
        .frame(
            width: PanelLayout.windowWidth,
            height: PanelLayout.windowHeight,
            alignment: .topLeading
        )
        .onAppear {
            // The panel is the first view to appear, so it is where the
            // SwiftUI window actions are captured for the AppKit side.
            WindowBridge.shared.adopt(openWindow: openWindow, openSettings: openSettings)
            model.contentHeight = desiredHeight
            reveal.finish(to: coordinator.panel.translation.count)
        }
        .onChange(of: desiredHeight) { _, new in
            // While text is arriving the shape grows a line at a time; running
            // an animation for each of those steps restarts it constantly and
            // costs more than the growth is worth. The animation is kept for
            // the discrete changes (opening, a new phase, the error view).
            if coordinator.panel.phase == .translating {
                model.contentHeight = new
            } else {
                withAnimation(.easeOut(duration: 0.16)) { model.contentHeight = new }
            }
        }
        .onChange(of: model.focusRequest) { _, _ in
            guard model.autoFocusEnabled else { return }
            sourceFocused = true
        }
        .onChange(of: coordinator.panel.sourceText) { _, _ in
            guard model.isOpen else { return }
            coordinator.panelTextChanged()
        }
        .onChange(of: coordinator.panel.translation) { _, new in
            reveal.update(count: new.count)
        }
    }

    // MARK: shape

    private var shape: some View {
        content
            .frame(width: PanelLayout.width, height: model.contentHeight, alignment: .top)
            .yakuGlass(in: .rect(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private var reduceMotion: Bool {
        AppearanceOverrides.reduceMotion
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.80)
    }

    private var closeAnimation: Animation { .easeInOut(duration: 0.18) }

    /// With "reduce motion" on the panel only fades, so it never grows.
    private var scale: CGFloat {
        reduceMotion ? 1 : (model.isOpen ? 1 : 0.96)
    }

    // MARK: content

    private var content: some View {
        Group {
            if model.isDropTarget {
                dropContent
            } else {
                normalContent
            }
        }
        .frame(width: PanelLayout.width, height: model.contentHeight, alignment: .top)
    }

    private var normalContent: some View {
        VStack(spacing: 0) {
            topBar
            sourceField
            if !isEmptyState {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: PanelLayout.dividerHeight)
                translationArea
            }
            bottomBar
            if let job = pdfRowJob {
                pdfRow(job)
            }
            quickBar
        }
        .frame(width: PanelLayout.width, height: model.contentHeight, alignment: .top)
    }

    /// SPEC 4.2 の「ドロップ」: the whole content becomes a well.
    private var dropContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary)
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text(model.dropMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(model.dropHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("レイアウトはそのまま")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: PanelLayout.width, height: model.contentHeight)
        .scaleEffect(model.dropHover ? 1.01 : 1.0)
        .animation(.snappy(duration: 0.25), value: model.dropHover)
    }

    // MARK: PDF row (SPEC 4.2 の 6)

    /// The job the row shows: one being processed, else the one that just
    /// finished, so 「開く」 stays reachable from the panel.
    private var pdfRowJob: PDFJob? {
        pdf.activeJob ?? pdf.recentlyFinished ?? pdf.recentlyFailed
    }

    private func pdfRow(_ job: PDFJob) -> some View {
        HStack(spacing: 8) {
            Image(systemName: job.jobState == .done ? "doc.text.fill" : "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(job.jobState == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.jobState {
                case .running, .queued:
                    Text(job.jobState == .queued ? "順番待ち" : PDFStage.japaneseName(for: job.stage))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ProgressThinBar(value: job.progress)
                case .done:
                    Text("完了 · \(String(format: "%.1f", job.seconds)) 秒")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .failed:
                    Text(job.errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                case .cancelled:
                    Text("取り消しました")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            switch job.jobState {
            case .done:
                rowButton("開く") { pdf.openOutput(job) }
                rowButton("対訳版") { pdf.openOutput(job, dual: true) }
                    .disabled(job.outputDualPath.isEmpty)
                rowButton("Finder で表示") { pdf.revealOutput(job) }
            case .running, .queued:
                rowButton("取り消し") { pdf.cancel(job) }
            case .failed:
                rowButton("もう一度") { pdf.retry(job) }
            case .cancelled:
                rowButton("もう一度") { pdf.retry(job) }
            }
        }
        .padding(.horizontal, PanelLayout.innerPadding)
        .frame(height: PanelLayout.pdfRowHeight)
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: .capsule)
    }

    private var isEmptyState: Bool {
        coordinator.panel.phase == .empty
    }

    // MARK: height

    private var desiredHeight: CGFloat {
        if model.isDropTarget { return PanelLayout.dropHeight }
        var height = PanelLayout.topBarHeight
        height += sourceFieldHeight
        if !isEmptyState {
            height += PanelLayout.dividerHeight
            height += translationHeight
        }
        height += PanelLayout.bottomBarHeight
        if pdfRowJob != nil {
            height += PanelLayout.pdfRowHeight
        }
        height += PanelLayout.quickBarHeight
        return min(max(height, PanelLayout.minHeight), PanelLayout.maxHeight)
    }

    private var sourceFieldHeight: CGFloat {
        if isEmptyState { return PanelLayout.emptySourceHeight }
        // Measuring the field's own frame would feed the constraint back into
        // itself, so the text is measured directly and clamped to 1...6 lines.
        let line = max(TextMetrics.lineHeight(
            size: PanelLayout.sourceFontSize,
            lineSpacing: PanelLayout.sourceLineSpacing
        ), 1)
        let measured = TextMetrics.height(
            coordinator.panel.sourceText,
            width: PanelLayout.contentWidth,
            size: PanelLayout.sourceFontSize,
            lineSpacing: PanelLayout.sourceLineSpacing
        )
        let lines = min(max(Int(ceil(measured / line)), 1), 6)
        return CGFloat(lines) * line + 16
    }

    private var translationHeight: CGFloat {
        switch coordinator.panel.phase {
        case .empty:
            return 0
        case .preparing:
            return PanelLayout.minimumTranslationHeight
        case .failed:
            // Just the message and its buttons; the error state must not leave
            // a wide empty face below them (M1 review).
            return 62
        case .translating:
            // The panel keeps one height while the translation streams and
            // fits the finished text when it lands. Growing it as text arrived
            // re-laid out the whole panel (glass, shadow and all) for every
            // step: measured 48% CPU growing in 44pt steps against 30% with a
            // fixed height (SPEC 14, M5). The height comes from the source
            // text, which does not change while the translation arrives.
            let wanted = max(sourceFieldHeight * 2.2, PanelLayout.workingTranslationHeight)
            return min(max(wanted, PanelLayout.minimumTranslationHeight),
                       max(availableTranslationHeight, PanelLayout.minimumTranslationHeight))
        case .done:
            let wanted = translationContentHeight + 16
            return min(max(wanted, PanelLayout.minimumTranslationHeight),
                       max(availableTranslationHeight, PanelLayout.minimumTranslationHeight))
        }
    }

    /// The height of the translation text.
    ///
    /// This is measured from the string rather than read back from the laid-out
    /// view. Reading it back put the panel's height in a loop with its own
    /// layout: every streamed piece changed the height, which re-laid out the
    /// panel (and the text), which reported a new height. Measured while a
    /// translation streamed, that loop cost 27 points of CPU (58% with it, 30%
    /// with the report removed); measuring the string costs one text
    /// measurement per evaluation and breaks the loop (SPEC 14, M5).
    private var translationContentHeight: CGFloat {
        TextMetrics.height(
            coordinator.panel.translation,
            width: PanelLayout.contentWidth,
            size: PanelLayout.translationFontSize,
            lineSpacing: PanelLayout.translationLineSpacing
        )
    }

    /// How tall the translation area may grow before the panel stops growing.
    private var availableTranslationHeight: CGFloat {
        PanelLayout.maxHeight
            - PanelLayout.topBarHeight
            - sourceFieldHeight
            - PanelLayout.dividerHeight
            - PanelLayout.bottomBarHeight
            - PanelLayout.quickBarHeight
    }

    // MARK: top band

    private var topBar: some View {
        HStack(spacing: 8) {
            languageMenu
            iconButton("arrow.left.arrow.right", help: "言語を入れ替える（⌘D）") {
                coordinator.swapLanguages()
            }

            Spacer(minLength: 4)

            if coordinator.panel.targetLanguage == "ja" {
                formToggle
            }
            pinButton
            moreMenu
        }
        .padding(.horizontal, PanelLayout.innerPadding)
        .frame(height: PanelLayout.topBarHeight)
    }

    private var languageMenu: some View {
        Menu {
            Button("自動（原文を判定）") { coordinator.clearManualPair() }
            Section("よく使う") {
                ForEach(LanguageCatalog.frequent) { language in
                    Button(language.japaneseName) {
                        coordinator.setManualTarget(language.code, forSource: coordinator.panel.sourceLanguage)
                    }
                }
            }
            Section("その他") {
                ForEach(LanguageCatalog.others) { language in
                    Button(language.japaneseName) {
                        coordinator.setManualTarget(language.code, forSource: coordinator.panel.sourceLanguage)
                    }
                }
            }
        } label: {
            // A single Text: a multi-view label came out reordered and clipped
            // inside the menu's own layout.
            Text(languageMenuTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("訳す言語を選ぶ")
        .accessibilityLabel("言語 \(LanguageCatalog.name(for: coordinator.panel.targetLanguage))")
    }

    private var languageMenuTitle: String {
        var title = LanguageCatalog.automaticName
        if let code = coordinator.panel.sourceLanguage {
            title += "（\(LanguageCatalog.name(for: code))）"
        }
        title += " → \(LanguageCatalog.name(for: coordinator.panel.targetLanguage))"
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

    private var pinButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { model.isPinned.toggle() }
        } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(model.isPinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("開いたままにする（⌘P）")
        .accessibilityLabel("開いたままにする")
        .accessibilityAddTraits(model.isPinned ? [.isSelected] : [])
    }

    private var moreMenu: some View {
        Menu {
            Button("管理画面を開く（⌘N）") {
                WindowBridge.shared.openManager()
            }
            Button("設定…") {
                WindowBridge.shared.openSettingsWindow()
            }
            Divider()
            Button("終了") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("その他")
        .accessibilityLabel("その他")
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: source

    private var sourceField: some View {
        TextField(
            "訳したい文を入力、またはファイルをここにドロップ",
            text: $coordinator.panel.sourceText,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: PanelLayout.sourceFontSize))
        .lineLimit(1...6)
        .focused($sourceFocused)
        .padding(.horizontal, PanelLayout.innerPadding)
        .padding(.top, 8)
        .frame(height: sourceFieldHeight, alignment: .top)
        .accessibilityLabel("訳したい文")
    }

    // MARK: translation

    @ViewBuilder
    private var translationText: some View {
        Text(coordinator.panel.translation)
            .font(.system(size: PanelLayout.translationFontSize))
            .lineSpacing(PanelLayout.translationLineSpacing)
            .textRenderer(FadeInTextRenderer(revealed: reveal.revealed))
            .textSelection(.enabled)
    }

    private var translationArea: some View {
        Group {
            switch coordinator.panel.phase {
            case .empty:
                Color.clear
            case .preparing:
                Text("準備しています…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("訳文、準備しています")
            case .translating, .done:
                translationScroll
            case .failed(let failure):
                failureView(failure)
            }
        }
        .padding(.horizontal, PanelLayout.innerPadding)
        .padding(.vertical, 8)
        .frame(height: translationHeight, alignment: .top)
    }

    /// What VoiceOver calls the translation area, which is also what says which
    /// phase the panel is in (SPEC 4.2 の状態).
    private var translationAreaLabel: String {
        switch coordinator.panel.phase {
        case .empty: return "訳文"
        case .preparing: return "訳文、準備しています"
        case .translating: return "訳文、翻訳中"
        case .done: return "訳文"
        case .failed(let failure): return "訳文、エラー、\(failure.message)"
        }
    }

    private var translationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                translationText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("translation")
            }
            .defaultScrollAnchor(.top)
            .scrollIndicators(.automatic)
            // Growing text keeps the top in view; `.defaultScrollAnchor`
            // alone still let the text view scroll to the end as the
            // translation streamed in.
            .onChange(of: coordinator.panel.scrollReset) { _, _ in
                proxy.scrollTo("translation", anchor: .top)
            }
            // VoiceOver names the translation as a whole, so it can be told
            // apart from the source field above it, and says which phase the
            // panel is in (SPEC 4.2 の状態, SPEC 18).
            .accessibilityLabel(translationAreaLabel)
        }
    }

    private func failureView(_ failure: TranslationCoordinator.TranslationFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 10) {
                Text(failure.message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("もう一度") { coordinator.retryPanel() }
                        .controlSize(.small)
                    if failure.showsLogButton {
                        Button("ログを見る") { NSWorkspace.shared.open(AppPaths.logsDirectory) }
                            .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("訳文、エラー、\(failure.message)")
    }

    // MARK: bottom band

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                statusText
                Spacer(minLength: 4)
                // Nothing to copy or open until there is a translation; the M1
                // review asked for these to disappear in the empty and error
                // states rather than sit there greyed out.
                if hasTranslation {
                    copyButton
                    iconButton("arrow.up.left.and.arrow.down.right", help: "管理画面で開く") {
                        WindowBridge.shared.openManager()
                    }
                }
            }
        }
        .frame(height: PanelLayout.bottomBarHeight)
        .padding(.horizontal, PanelLayout.innerPadding)
    }

    private var hasTranslation: Bool {
        !coordinator.panel.translation.isEmpty
    }

    @ViewBuilder
    private var statusText: some View {
        if let elapsed = coordinator.panel.elapsed {
            Text(String(format: "%.2f 秒 · %@ · この Mac の中で処理",
                        elapsed, coordinator.modelDisplayName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: elapsed)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var copyButton: some View {
        Button {
            let text = coordinator.panel.translation
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            withAnimation(.snappy(duration: 0.25)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.snappy(duration: 0.25)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(coordinator.panel.translation.isEmpty
                    ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(coordinator.panel.translation.isEmpty)
        .help("訳文をコピー（⌘⇧C）")
        .accessibilityLabel("訳文をコピー")
    }

    // MARK: quick actions

    private var quickBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                quickButton("画面を翻訳", systemImage: "text.viewfinder", shortcut: "⌃⌥O") {
                    onScreenTranslate()
                }
                quickButton("PDF を開く", systemImage: "doc.text", shortcut: "⌘O") {
                    onOpenPDF()
                }
                quickButton("履歴", systemImage: "clock", shortcut: nil) {
                    WindowBridge.shared.openManager(page: .history)
                    NSApp.keyWindow?.resignKey()
                }
            }
        }
        .frame(height: PanelLayout.quickBarHeight)
        .padding(.horizontal, PanelLayout.innerPadding)
    }

    private func quickButton(
        _ title: String,
        systemImage: String,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(shortcut.map { "\(title)（\($0)）" } ?? title)
        .accessibilityLabel(title)
    }
}

/// The 3pt progress line in the panel's PDF row (SPEC 4.2 の 6).
struct ProgressThinBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: Palette.glow, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// One small horizontal shake, used when a non-PDF file is dropped (SPEC 4.2).
struct PanelShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 2), y: 0))
    }
}
