import SwiftUI
import YakuCore

/// The settings window (SPEC 4.4). A `Settings` scene with one tab per row of
/// the specification's table; the PDF and overlay tabs show the M3 / M4 items
/// but leave them inert.
struct SettingsRootView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: ManagerModel
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var pdf: PDFQueue
    @Bindable var state: SettingsState

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
        .frame(width: 560)
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
                    Text("登録できませんでした。~/Applications に置いた Yaku.app で試してください。")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Text("システム設定の「ログイン項目」に「Yaku」として出ます。いまの状態: \(LoginItem.statusText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                Text("文体は目的の言語が日本語のときだけ使われます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("入力後に自動で訳す", isOn: $settings.autoTranslate)
                Toggle("ノッチを使う", isOn: $settings.useNotch)
                Text("ノッチは PDF のドロップ先と進み具合に使います。ノッチのある画面でだけ出ます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    var body: some View {
        Form {
            Section {
                ForEach(settings.shortcutBindings, id: \.id) { binding in
                    ShortcutRow(
                        title: ShortcutDefaults.displayName(for: binding.id),
                        help: help(for: binding.id),
                        settings: settings,
                        bindingID: binding.id,
                        conflicted: conflicts.contains(binding.id)
                    )
                }
            }
            if !conflicts.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("同じキーが重なっています。どちらかを変えてください。")
                            .font(.system(size: 12))
                    }
                }
            }
            Section {
                Text("パネルの中では ⌘↩（訳す）、⌘⇧C（コピー）、⌘D（入れ替え）、⌘O（PDF）、⌘P（ピン）、⌘N（管理画面）が使えます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                Text("変えるとエンジンを起動し直します。ファイルは「モデル」の画面で取得できます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            }

            Section {
                LabeledContent("状態", value: model.engineStatusText)
                LabeledContent("待ち受け", value: model.engineMemoryText)
                HStack {
                    Button("起動し直す") { Task { await model.engine.restart() } }
                    Button("止める") { Task { await model.engine.stop() } }
                        .disabled(!model.engine.isRunning)
                }
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
                LabeledContent("PDF ワーカー", value: workerStateText)
                if pdf.installer.phase == .running {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: pdf.installer.progress)
                        Text(pdf.installer.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("取り消す") { pdf.installer.cancel() }
                            .controlSize(.small)
                    }
                } else {
                    HStack {
                        Button("導入する") { Task { await pdf.installer.install() } }
                            .disabled(PDFWorkerPaths.isInstalled || pdf.installer.phase == .running)
                        Button("削除", role: .destructive) { PDFWorkerPaths.removeInstallation() }
                            .disabled(!PDFWorkerPaths.isInstalled)
                    }
                    if case .failed(let message) = pdf.installer.phase {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    Text("PDF の翻訳には追加の部品（約 \(PDFWorkerInstaller.estimatedSizeText)、取得に数分）が必要です。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("出力先", selection: $settings.pdfOutputSameFolder) {
                    Text("元のファイルと同じ場所").tag(true)
                    Text("選んだフォルダ").tag(false)
                }
                if !settings.pdfOutputSameFolder {
                    HStack {
                        Text(outputFolderText)
                            .font(.system(size: 12))
                            .foregroundStyle(settings.pdfOutputFolder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("選ぶ…") { chooseOutputFolder() }
                            .controlSize(.small)
                    }
                }
                Toggle("完了したら開く", isOn: $settings.pdfOpenWhenDone)
                Toggle("対訳版も作る", isOn: $settings.pdfMakeDual)
            }

            Section {
                HStack {
                    Text(pythonPathText)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.pdfPythonPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("選ぶ…") { choosePython() }
                        .controlSize(.small)
                    if !settings.pdfPythonPath.isEmpty {
                        Button("既定に戻す") { settings.pdfPythonPath = "" }
                            .controlSize(.small)
                    }
                }
                Text("開発用: lab の .venv/bin/python を選ぶと、そちらで PDF を訳します。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onAppear { refreshSize() }
    }

    private var workerStateText: String {
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
                LabeledContent("重ねる文字の最小の大きさ") {
                    HStack {
                        Slider(value: $settings.overlayMinScale, in: 0.5...1.0, step: 0.05) {
                            Text("最小の大きさ")
                        }
                        .frame(width: 180)
                        Text("元の \(Int((settings.overlayMinScale * 100).rounded()))%")
                            .font(.system(size: 12))
                            .monospacedDigit()
                    }
                }
            }

            Section {
                Text("読み取る言語を「自動」にすると、画面の文字から言語を判定します。"
                    + "訳は元の文字の位置に重ねて出ます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            }

            Section {
                HStack {
                    Button("履歴とキャッシュを消す", role: .destructive) {
                        model.store.deleteAllHistory()
                        model.store.deleteAllCache()
                        model.reloadHistory()
                        model.selectedHistory = nil
                        cleared = true
                        AppLog.write("privacy: history and cache cleared")
                    }
                    if cleared {
                        Text("消しました")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("訳した文はこの Mac の外に出ません。ネットワークを使うのはモデルの取得だけです。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}
