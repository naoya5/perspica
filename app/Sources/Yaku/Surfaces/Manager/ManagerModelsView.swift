import AppKit
import SwiftUI
import YakuCore

/// 管理画面の「モデル」(SPEC 4.4, 7.5): a card per model with its size, memory
/// estimate and state, plus 取得 / 削除 / 使う and the licence gate.
struct ManagerModelsView: View {
    @Bindable var model: ManagerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                DesignSection("モデル", note: model.modelNote) {
                    VStack(alignment: .leading, spacing: Design.Space.l) {
                        ForEach(ModelCatalog.models) { entry in
                            card(entry)
                        }
                    }
                }

                existingFileCard
                engineCard
                licensesCard
            }
            .padding(Design.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("モデル")
        .sheet(item: $model.licenseModel) { entry in
            LicenseSheet(model: model, entry: entry)
        }
        .onAppear { model.refreshInstalled() }
    }

    // MARK: cards

    private func card(_ entry: TranslationModel) -> some View {
        let installed = model.isInstalled(entry)
        let downloading = model.downloader.state.modelID == entry.id && model.downloader.state.isActive
        let selected = AppSettings.shared.selectedModelID == entry.id
            && AppSettings.shared.customModelPath.isEmpty
        // The engine is running the development file for this entry, so say
        // that instead of 「未取得」 (SPEC 15).
        let development = !installed && !downloading
            && ModelCatalog.models.first?.id == entry.id
            && ModelStore.isUsingDevelopmentFile

        return VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(entry.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if selected {
                    DesignBadge(text: "使用中", systemImage: "checkmark.circle.fill", tone: .accent)
                }
                Spacer(minLength: Design.Space.s)
                // One badge shape for every state, so 使用中 / 未取得 /
                // 取得中 read as the same kind of thing.
                stateBadge(entry, installed: installed, downloading: downloading,
                           development: development)
            }

            HStack(spacing: Design.Space.l) {
                detail("大きさ", entry.sizeInGigabytes)
                detail("必要なメモリ", entry.memoryHint)
                detail("速さ", entry.speedHint)
                detail("形式", "GGUF Q4_K_M")
            }

            if downloading {
                let state = model.downloader.state
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    ProgressView(value: state.progress)
                    HStack {
                        Text(state.progressText)
                        if !state.speedText.isEmpty { Text("· \(state.speedText)") }
                        Spacer()
                        Button("取り消す") { model.cancelDownload() }
                            .controlSize(.small)
                    }
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            } else if let message = downloadMessage(entry) {
                Text(message)
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.secondary)
            }

            if let note = entry.memoryNote {
                Text(note)
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.secondary)
            }

            if development {
                Text("この Mac では開発用のファイル（YAKU_DEV_MODEL）を使っています。"
                     + "「取得する」で正規のファイルを取得すると、そちらに差し替わります。")
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Design.Space.s) {
                if !installed {
                    Button("取得する") { model.requestDownload(entry) }
                        .disabled(model.downloader.state.isActive)
                } else {
                    Button("使う") { model.useModel(entry) }
                        .disabled(selected)
                    Button("削除", role: .destructive) { model.deleteModel(entry) }
                }
                Spacer(minLength: Design.Space.s)
                Text(entry.repository)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .designCard()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: Design.Font.label))
                .monospacedDigit()
        }
    }

    /// The one badge every state goes through The wording is plain; 取得中
    /// carries the percentage.
    private func stateBadge(_ entry: TranslationModel, installed: Bool, downloading: Bool,
                            development: Bool = false) -> DesignBadge {
        if downloading {
            let percent = Int((model.downloader.state.progress * 100).rounded())
            return DesignBadge(text: "取得中 \(percent)%",
                               systemImage: "arrow.down.circle", tone: .accent)
        }
        if installed {
            return DesignBadge(text: "取得済み", systemImage: "checkmark.circle", tone: .success)
        }
        if development {
            return DesignBadge(text: "開発用のファイルを使用中",
                               systemImage: "hammer", tone: .warning)
        }
        let partial = model.partialBytes(entry)
        if partial > 0 {
            return DesignBadge(text: "途中まで（\(ByteCount.format(partial))）",
                               systemImage: "pause.circle", tone: .warning)
        }
        return DesignBadge(text: "未取得", systemImage: "circle.dashed", tone: .neutral)
    }

    private func downloadMessage(_ entry: TranslationModel) -> String? {
        guard model.downloader.state.modelID == entry.id else { return nil }
        switch model.downloader.state.phase {
        case .cancelled:
            let partial = model.partialBytes(entry)
            return "取り消しました（\(ByteCount.format(partial)) まで取得済み。「取得する」で続きから）"
        case .verifying:
            return "SHA-256 を確かめています…"
        case .failed(let message):
            return "取得できませんでした: \(message)"
        default:
            return nil
        }
    }

    // MARK: existing file and engine

    private var existingFileCard: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("既存のファイルを使う")
                .font(.system(size: Design.Font.body, weight: .semibold))
            Text(AppSettings.shared.customModelPath.isEmpty
                 ? "手元の GGUF を選んで使えます。"
                 : "いま: \(AppSettings.shared.customModelPath)")
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: Design.Space.s) {
                Button("ファイルを選ぶ…") { chooseFile() }
                if !AppSettings.shared.customModelPath.isEmpty {
                    Button("既定に戻す") {
                        AppSettings.shared.customModelPath = ""
                        model.modelNote = "既定のモデルに戻しました"
                        Task { await model.engine.restart() }
                    }
                }
            }
        }
        .designCard()
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("エンジン")
                .font(.system(size: Design.Font.body, weight: .semibold))
            HStack(spacing: Design.Space.l) {
                detail("状態", model.engineStatusText)
                detail("待ち受け", model.engineMemoryText)
                detail("止めるまで", idleText)
            }
            HStack(spacing: Design.Space.s) {
                Button("起動し直す") {
                    Task { await model.engine.restart() }
                }
                Button("止める") {
                    Task { await model.engine.stop() }
                }
                .disabled(!model.engine.isRunning)
            }
        }
        .designCard()
    }

    private var idleText: String {
        let minutes = AppSettings.shared.engineIdleMinutes
        return minutes <= 0 ? "止めない" : "\(minutes) 分"
    }

    private var licensesCard: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("ライセンス")
                .font(.system(size: Design.Font.body, weight: .semibold))
            Text("Built with PLaMo")
                .font(.system(size: Design.Font.caption))
            Text("翻訳モデルにはPLaMo Community Licenseが適用されます。翻訳エンジンの llama.cpp には MIT ライセンスが適用されます。")
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.s) {
                Link("モデルの利用条件", destination: ModelCatalog.licenseURL)
                Button("第三者の著作権・ライセンス") {
                    openLicenseDocument("THIRD_PARTY_NOTICES")
                }
                .disabled(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") == nil)
            }
            .controlSize(.small)
        }
        .designCard()
    }

    private func openLicenseDocument(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "GGUF のファイルを選ぶ"
        panel.directoryURL = ModelStore.developmentModelPath
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useExistingFile(url)
    }
}

/// The PLaMo Community License gate shown before a download (SPEC 4.4).
struct LicenseSheet: View {
    @Bindable var model: ManagerModel
    let entry: TranslationModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("PLaMo Community License")
                .font(.system(size: Design.Font.sectionTitle, weight: .semibold))
            Text("2026年11月9日改訂 · Built with PLaMo")
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.secondary)
            Text("\(entry.displayName) を取得する前に、ライセンスを確認してください。")
                .font(.system(size: Design.Font.label))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(licenseText ?? "ライセンスの全文を読み込めません。アプリを入れ直してください。公式ページでも全文を確認できます。")
                    .font(.system(size: Design.Font.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            .padding(Design.Space.s)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Design.Radius.field, style: .continuous))

            HStack {
                Link("ライセンスの全文を開く",
                     destination: ModelCatalog.licenseURL)
                    .font(.system(size: Design.Font.caption))
                Spacer()
                Button("やめる") {
                    model.licenseModel = nil
                    dismiss()
                }
                Button("同意して取得する") {
                    model.acceptLicense(for: entry)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(licenseText == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.pagePadding)
        .frame(width: 560)
    }

    /// Do not accept an abbreviated or missing copy of the publisher's terms.
    private var licenseText: String? {
        if let url = Bundle.main.url(forResource: "PLAMO-COMMUNITY-LICENSE-en", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return nil
    }
}
