import AppKit
import SwiftUI
import YakuCore

/// 管理画面の「モデル」(SPEC 4.4, 7.5): a card per model with its size, memory
/// estimate and state, plus 取得 / 削除 / 使う and the licence gate.
struct ManagerModelsView: View {
    @Bindable var model: ManagerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ManagerSectionLabel(text: "モデル")
                    Spacer()
                    if let note = model.modelNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(ModelCatalog.models) { entry in
                    card(entry)
                }

                existingFileCard
                engineCard
            }
            .padding(20)
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
        // The engine is running M0's development file for this entry, so say
        // that instead of 「未取得」 (SPEC 15, M5).
        let development = !installed && !downloading
            && ModelCatalog.models.first?.id == entry.id
            && ModelStore.isUsingDevelopmentFile

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if selected {
                    Text("使用中")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: .capsule)
                }
                Spacer()
                Text(stateText(entry, installed: installed, downloading: downloading,
                               development: development))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                detail("大きさ", entry.sizeInGigabytes)
                detail("必要なメモリ", entry.memoryHint)
                detail("速さ", entry.speedHint)
                detail("形式", "GGUF Q4_K_M")
            }

            if downloading {
                let state = model.downloader.state
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: state.progress)
                    HStack {
                        Text(state.progressText)
                        if !state.speedText.isEmpty { Text("· \(state.speedText)") }
                        Spacer()
                        Button("取り消す") { model.cancelDownload() }
                            .controlSize(.small)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            } else if let message = downloadMessage(entry) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let note = entry.memoryNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if development {
                Text("この Mac では M0 で用意した開発用のファイルを使っています。"
                     + "「取得する」で正規のファイルを取得すると、そちらに差し替わります。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if !installed {
                    Button("取得する") { model.requestDownload(entry) }
                        .disabled(model.downloader.state.isActive)
                } else {
                    Button("使う") { model.useModel(entry) }
                        .disabled(selected)
                    Button("削除", role: .destructive) { model.deleteModel(entry) }
                }
                Spacer()
                Text(entry.repository)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }

    private func stateText(_ entry: TranslationModel, installed: Bool, downloading: Bool,
                           development: Bool = false) -> String {
        if downloading { return "取得中" }
        if installed { return "取得済み" }
        if development { return "開発用のファイルを使用中" }
        let partial = model.partialBytes(entry)
        if partial > 0 { return "途中まで（\(ByteCount.format(partial))）" }
        return "未取得"
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
        VStack(alignment: .leading, spacing: 8) {
            Text("既存のファイルを使う")
                .font(.system(size: 13, weight: .semibold))
            Text(AppSettings.shared.customModelPath.isEmpty
                 ? "手元の GGUF を選んで使えます。"
                 : "いま: \(AppSettings.shared.customModelPath)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("エンジン")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 16) {
                detail("状態", model.engineStatusText)
                detail("待ち受け", model.engineMemoryText)
                detail("止めるまで", idleText)
            }
            HStack(spacing: 8) {
                Button("起動し直す") {
                    Task { await model.engine.restart() }
                }
                Button("止める") {
                    Task { await model.engine.stop() }
                }
                .disabled(!model.engine.isRunning)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var idleText: String {
        let minutes = AppSettings.shared.engineIdleMinutes
        return minutes <= 0 ? "止めない" : "\(minutes) 分"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "GGUF のファイルを選ぶ"
        panel.directoryURL = URL(fileURLWithPath: ModelStore.developmentModelPath)
            .deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useExistingFile(url)
    }
}

/// The PLaMo Community License gate shown before a download (SPEC 4.4).
private struct LicenseSheet: View {
    @Bindable var model: ManagerModel
    let entry: TranslationModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PLaMo Community License")
                .font(.system(size: 15, weight: .semibold))
            Text("\(entry.displayName) を取得する前に、ライセンスを確認してください。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(licenseText)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8, style: .continuous))

            HStack {
                Link("ライセンスの全文を開く",
                     destination: URL(string: "https://plamo.preferredai.jp/info/plamo-community-license-en")!)
                    .font(.system(size: 11))
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
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The bundled copy of the licence, or the key points when the app is run
    /// straight out of the build directory (where there is no bundle).
    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "PLAMO-COMMUNITY-LICENSE-en", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return """
        PLaMo Community License Agreement（要点）

        ・個人利用（学習・趣味）と学術利用は、事前の登録なしで無償です。
        ・商用利用は、PFN の登録ページでの事前登録と、年間売上 10 億円以下という条件を満たす
          場合だけ許可されます。
        ・MODEL MATERIALS を第三者に渡すときは、本契約の写しを渡し、「Built with PLaMo」を
          表示し、AI モデル名に「PLaMo」を含める必要があります。
        ・出力は、モデルの出力であることを明示すれば公開できます。
        ・モデルと出力は現状のまま提供され、PFN は保証しません。

        全文: https://plamo.preferredai.jp/info/plamo-community-license-en
        """
    }
}
