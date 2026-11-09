import SwiftUI
import YakuCore

/// The settings window (SPEC 4.4). A `Settings` scene with one tab per row of
/// the specification's table; the PDF and overlay tabs show the M3 / M4 items
/// but leave them inert.
///
/// M7: every tab is built the same way (a section heading, the card, the
/// explanation as the section's footer), and the window is only as tall as the
/// tab it is showing, so a short tab does not leave half a window empty.
struct SettingsRootView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: ManagerModel
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var pdf: PDFQueue
    @Bindable var state: SettingsState

    @State private var contentHeight: CGFloat = 0

    /// SPEC 4.4: the width is fixed; M7 changes only the height.
    private static let width: CGFloat = 560

    var body: some View {
        TabView(selection: $state.tab) {
            GeneralSettingsTab(settings: settings, state: state)
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
            ShortcutSettingsTab(settings: settings, state: state)
                .tabItem { Label(SettingsTab.shortcuts.title, systemImage: SettingsTab.shortcuts.systemImage) }
                .tag(SettingsTab.shortcuts)
            EngineSettingsTab(settings: settings, model: model, state: state)
                .tabItem { Label(SettingsTab.engine.title, systemImage: SettingsTab.engine.systemImage) }
                .tag(SettingsTab.engine)
            PDFSettingsTab(settings: settings, pdf: pdf, state: state)
                .tabItem { Label(SettingsTab.pdf.title, systemImage: SettingsTab.pdf.systemImage) }
                .tag(SettingsTab.pdf)
            OverlaySettingsTab(settings: settings, state: state)
                .tabItem { Label(SettingsTab.overlay.title, systemImage: SettingsTab.overlay.systemImage) }
                .tag(SettingsTab.overlay)
            PrivacySettingsTab(settings: settings, model: model, coordinator: coordinator, state: state)
                .tabItem { Label(SettingsTab.privacy.title, systemImage: SettingsTab.privacy.systemImage) }
                .tag(SettingsTab.privacy)
        }
        .frame(width: Self.width)
        // A `Form` in the grouped style has an intrinsic height, so the tab
        // view does too; `fixedSize` makes the view that height instead of
        // stretching to the window. The height is then handed to the window.
        .fixedSize(horizontal: false, vertical: true)
        .measureContentHeight()
        .onPreferenceChange(ContentHeightKey.self) { height in
            guard height > 0 else { return }
            contentHeight = height
        }
        .background(SettingsWindowSizer(contentHeight: contentHeight, width: Self.width))
        // The settings window is a hand-opened window like the manager, so it
        // needs the same treatment: an accessory app's window does not come to
        // the front on its own.
        .background(WindowProbe { window in
            WindowActivation.shared.activate(window)
        })
        .onAppear {
            AppLog.write("settings: appeared on \(state.tab.rawValue)")
        }
        .onDisappear {
            DispatchQueue.main.async {
                WindowActivation.shared.windowDidDisappear()
            }
        }
    }
}

// MARK: 一般

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var state: SettingsState

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in
                        launchAtLoginFailed = !LoginItem.setEnabled(new)
                        if launchAtLoginFailed { launchAtLogin = LoginItem.isEnabled }
                    }
                if launchAtLoginFailed {
                    Text("登録できませんでした。~/Applications に置いた Perspica.app で試してください。")
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("起動")
            } footer: {
                Text("システム設定の「ログイン項目」に「Perspica」として出ます。いまの状態: \(LoginItem.statusText)")
            }

            Section {
                Picker("既定の目的の言語", selection: $settings.defaultTargetLanguage) {
                    ForEach(LanguageCatalog.frequent) { language in
                        Text(language.japaneseName).tag(language.code)
                    }
                    Divider()
                    ForEach(LanguageCatalog.others) { language in
                        Text(language.japaneseName).tag(language.code)
                    }
                }
                Picker("既定の文体", selection: $settings.defaultForm) {
                    Text("である").tag(TranslationForm.plain)
                    Text("です・ます").tag(TranslationForm.polite)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("翻訳")
            } footer: {
                Text("文体は目的の言語が日本語のときだけ使われます。")
            }

            Section {
                Toggle("入力後に自動で訳す", isOn: $settings.autoTranslate)
                Toggle("ノッチを使う", isOn: $settings.useNotch)
            } header: {
                Text("動作")
            } footer: {
                Text("ノッチは PDF のドロップ先と進み具合に使います。ノッチのある画面でだけ出ます。")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: ショートカット

private struct ShortcutSettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var state: SettingsState
    private let hotKeyStatus = HotKeyStatus.shared

    var body: some View {
        Form {
            Section {
                ForEach(settings.shortcutBindings, id: \.id) { binding in
                    ShortcutRow(
                        title: ShortcutDefaults.displayName(for: binding.id),
                        help: help(for: binding.id),
                        settings: settings,
                        bindingID: binding.id,
                        conflicted: conflicts.contains(binding.id),
                        registrationFailed: hotKeyStatus.failedBindingIDs.contains(binding.id)
                    )
                }
            } header: {
                Text("キー")
            } footer: {
                Text("欄を押してからキーを押すと登録できます。どれもどこでも効きます。")
            }

            if !hotKeyStatus.failedBindingIDs.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: Design.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("他のアプリが同じキーを使っているので、このキーは効きません。別のキーにしてください。")
                            .font(.system(size: Design.Font.label))
                    }
                } header: {
                    Text("使えないキー")
                }
            }

            if !conflicts.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: Design.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("同じキーが重なっています。どちらかを変えてください。")
                            .font(.system(size: Design.Font.label))
                    }
                } header: {
                    Text("重なり")
                }
            }

            Section {
                Text("パネルの中では ⌘↩（訳す）、⌘⇧C（コピー）、⌘D（入れ替え）、⌘O（PDF）、⌘P（ピン）、⌘N（管理画面）が使えます。")
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.secondary)
            } header: {
                Text("パネルの中")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private func help(for id: String) -> String {
        "どこでも効きます"
    }

    private var conflicts: Set<String> {
        ShortcutConflict.conflictingIDs(settings.shortcutBindings)
    }
}

// MARK: エンジン

private struct EngineSettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var model: ManagerModel
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                Picker("使うモデル", selection: $settings.selectedModelID) {
                    ForEach(ModelCatalog.models) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
                .onChange(of: settings.selectedModelID) { _, _ in
                    settings.customModelPath = ""
                    Task { await model.engine.restart() }
                }
            } header: {
                Text("モデル")
            } footer: {
                Text("変えるとエンジンを起動し直します。ファイルは「モデル」の画面で取得できます。Built with PLaMo（PLaMo 3 Translate、Preferred Networks）。")
            }

            Section {
                Picker("使わないときに止めるまでの時間", selection: $settings.engineIdleMinutes) {
                    Text("5 分").tag(5)
                    Text("10 分").tag(10)
                    Text("30 分").tag(30)
                    Text("止めない").tag(0)
                }
                .onChange(of: settings.engineIdleMinutes) { _, new in
                    model.engine.configure(idleSeconds: new <= 0 ? 0 : Double(new) * 60)
                }
            } header: {
                Text("停止")
            } footer: {
                Text("PDF の処理中は止まりません。")
            }

            Section {
                LabeledContent("状態", value: model.engineStatusText)
                LabeledContent("待ち受け", value: model.engineMemoryText)
                HStack(spacing: Design.Space.s) {
                    Button("起動し直す") { Task { await model.engine.restart() } }
                    Button("止める") { Task { await model.engine.stop() } }
                        .disabled(!model.engine.isRunning)
                }
            } header: {
                Text("状態")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: PDF（SPEC 4.4）

private struct PDFSettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var pdf: PDFQueue
    @Bindable var state: SettingsState

    @State private var sizeText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("状態", value: workerStateText)
                if pdf.installer.phase == .running {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        ProgressView(value: pdf.installer.progress)
                        Text(pdf.installer.message)
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.secondary)
                        Button("取り消す") { pdf.installer.cancel() }
                            .controlSize(.small)
                    }
                } else {
                    HStack(spacing: Design.Space.s) {
                        Button("導入する") { Task { await pdf.installer.install() } }
                            .disabled(PDFWorkerPaths.isInstalled || pdf.installer.phase == .running)
                        Button("削除", role: .destructive) { PDFWorkerPaths.removeInstallation() }
                            .disabled(!PDFWorkerPaths.isInstalled)
                    }
                    if case .failed(let message) = pdf.installer.phase {
                        Text(message)
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("PDF ワーカー")
            } footer: {
                Text("PDF の翻訳には追加の部品（約 \(PDFWorkerInstaller.estimatedSizeText)、取得に数分）が必要です。")
            }

            Section {
                Picker("出力先", selection: $settings.pdfOutputSameFolder) {
                    Text("元のファイルと同じ場所").tag(true)
                    Text("選んだフォルダ").tag(false)
                }
                if !settings.pdfOutputSameFolder {
                    HStack(spacing: Design.Space.s) {
                        Text(outputFolderText)
                            .font(.system(size: Design.Font.label))
                            .foregroundStyle(settings.pdfOutputFolder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Design.Space.s)
                        Button("選ぶ…") { chooseOutputFolder() }
                            .controlSize(.small)
                    }
                }
                Toggle("完了したら開く", isOn: $settings.pdfOpenWhenDone)
                Toggle("対訳版も作る", isOn: $settings.pdfMakeDual)
            } header: {
                Text("出力")
            }

            Section {
                HStack(spacing: Design.Space.s) {
                    Text(pythonPathText)
                        .font(.system(size: Design.Font.label))
                        .foregroundStyle(settings.pdfPythonPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Design.Space.s)
                    Button("選ぶ…") { choosePython() }
                        .controlSize(.small)
                    if !settings.pdfPythonPath.isEmpty {
                        Button("既定に戻す") { settings.pdfPythonPath = "" }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("開発用")
            } footer: {
                Text("lab の .venv/bin/python を選ぶと、そちらで PDF を訳します。")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onAppear { refreshSize() }
    }

    private var workerStateText: String {
        if PDFWorkerPaths.demoInstalled {
            return sizeText.isEmpty ? "導入済み" : "導入済み（\(sizeText)）"
        }
        if !settings.pdfPythonPath.isEmpty { return "開発用の Python を使います" }
        guard PDFWorkerPaths.isInstalled else { return "未導入" }
        return sizeText.isEmpty ? "導入済み" : "導入済み（\(sizeText)）"
    }

    private var pythonPathText: String {
        if !settings.pdfPythonPath.isEmpty { return settings.pdfPythonPath }
        return PDFWorkerPaths.isInstalled
            ? PDFWorkerPaths.installedPython.path
            : "未導入（自動で入れる場所: \(PDFWorkerPaths.installedPython.path)）"
    }

    private var outputFolderText: String {
        settings.pdfOutputFolder.isEmpty ? "まだ選んでいません" : settings.pdfOutputFolder
    }

    private func refreshSize() {
        guard PDFWorkerPaths.isInstalled else {
            sizeText = ""
            return
        }
        sizeText = ByteCount.format(PDFWorkerPaths.installedBytes)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選ぶ"
        if panel.runModal() == .OK, let url = panel.url {
            settings.pdfOutputFolder = url.path
        }
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "選ぶ"
        if panel.runModal() == .OK, let url = panel.url {
            settings.pdfPythonPath = url.path
        }
    }
}

// MARK: 画面翻訳（SPEC 4.4）

private struct OverlaySettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                Picker("読み取る言語", selection: $settings.overlayLanguage) {
                    Text("自動").tag("auto")
                    Section("よく使う") {
                        ForEach(LanguageCatalog.frequent) { language in
                            Text(language.japaneseName).tag(language.code)
                        }
                    }
                    Section("その他") {
                        ForEach(LanguageCatalog.others) { language in
                            Text(language.japaneseName).tag(language.code)
                        }
                    }
                }
            } header: {
                Text("読み取り")
            } footer: {
                Text("「自動」にすると、画面の文字から言語を判定します。")
            }

            Section {
                // M7: the value sits with the label on the top line, and the
                // slider gets the full width under it, instead of the value
                // being wedged beside a short slider.
                HStack {
                    Text("重ねる文字の最小の大きさ")
                    Spacer(minLength: Design.Space.s)
                    Text("元の \(Int((settings.overlayMinScale * 100).rounded()))%")
                        .font(.system(size: Design.Font.label))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Slider(value: $settings.overlayMinScale, in: 0.5...1.0, step: 0.05) {
                    Text("重ねる文字の最小の大きさ")
                }
                .labelsHidden()
            } header: {
                Text("重ねる文字")
            } footer: {
                Text("訳は元の文字の位置に重ねて出ます。小さすぎる文字は訳しません。")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: プライバシー

private struct PrivacySettingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var model: ManagerModel
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var state: SettingsState

    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Toggle("履歴を残す", isOn: $settings.keepHistory)
                Picker("残す期間", selection: $settings.historyRetentionDays) {
                    Text("30 日").tag(30)
                    Text("90 日").tag(90)
                    Text("ずっと").tag(0)
                }
                .disabled(!settings.keepHistory)
            } header: {
                Text("履歴")
            } footer: {
                Text("期間を過ぎた履歴は起動時に消します。")
            }

            Section {
                HStack(spacing: Design.Space.s) {
                    Button("履歴とキャッシュを消す", role: .destructive) {
                        model.store.deleteAllHistory()
                        model.store.deleteAllCache()
                        URLCacheLeftovers.remove()
                        PDFWorkerPaths.clearTranslationCache()
                        AppLog.clearAll()
                        model.reloadHistory()
                        model.selectedHistory = nil
                        cleared = true
                        AppLog.write("privacy: history, caches and logs cleared")
                    }
                    if cleared {
                        Text("消しました")
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("消去")
            } footer: {
                Text("履歴、訳のキャッシュ、PDF の訳のキャッシュ、ログを消します。訳した文はこの Mac の外に出ません。ネットワークを使うのは、モデルの取得と、PDF 用の部品の取得（初めて PDF を訳すとき）だけです。")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}
