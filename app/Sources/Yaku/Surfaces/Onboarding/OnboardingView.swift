import AppKit
import SwiftUI
import YakuCore

/// The first-run guide (SPEC 4.7): four pages in a manager-sized window.
struct OnboardingView: View {
    @Bindable var model: ManagerModel
    @Bindable var coordinator: TranslationCoordinator
    let initialPage: Int

    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(WindowProbe { window in
            WindowActivation.shared.activate(window)
        })
        .onAppear {
            page = min(max(initialPage - 1, 0), 3)
            model.refreshInstalled()
            AppLog.write("onboarding: appeared page=\(page + 1)")
        }
        .onDisappear {
            DispatchQueue.main.async {
                WindowActivation.shared.windowDidDisappear()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: modelPage
        case 2: permissionPage
        default: menuBarPage
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            Spacer()
            if page > 0 {
                Button("戻る") { withAnimation(.snappy(duration: 0.25)) { page -= 1 } }
            }
            Button(page == 3 ? "使い始める" : "続ける") {
                if page == 3 {
                    AppSettings.shared.hasSeenOnboarding = true
                    AppLog.write("onboarding: finished")
                    dismiss()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { page += 1 }
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: 1. ようこそ

    private var welcomePage: some View {
        pageLayout(
            systemImage: "character.bubble",
            title: "Perspica へようこそ",
            message: "選んだ文、入力した文、PDF、画面の文字を、この Mac の中だけで訳します。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                bullet("訳した文はネットワークに出ません。使うのはモデルの取得のときだけです。")
                bullet("メニューバーに常駐し、⌃⌥J で選んだ文をすぐ訳せます。")
                bullet("Apple の Liquid Glass に合わせた見た目で、ほかのアプリの邪魔をしません。")
            }
        }
    }

    // MARK: 2. モデル

    private var modelPage: some View {
        pageLayout(
            systemImage: "shippingbox",
            title: "翻訳モデルを用意する",
            message: "0.8B をおすすめします（0.57 GB）。あとから 2B / 8B に変えられます。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let entry = ModelCatalog.models.first {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(entry.sizeInGigabytes) · 必要なメモリ \(entry.memoryHint) · \(entry.speedHint)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isInstalled(entry) {
                            Label("取得済み", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        } else if model.downloader.state.modelID == entry.id,
                                  model.downloader.state.isActive {
                            Button("取り消す") { model.cancelDownload() }
                        } else {
                            Button("取得する") { model.requestDownload(entry) }
                                .buttonStyle(.glassProminent)
                        }
                    }

                    if model.downloader.state.modelID == entry.id,
                       model.downloader.state.isActive {
                        ProgressView(value: model.downloader.state.progress)
                        HStack {
                            Text(model.downloader.state.progressText)
                            if !model.downloader.state.speedText.isEmpty {
                                Text("· \(model.downloader.state.speedText)")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }

                HStack(spacing: 10) {
                    Button("既存のファイルを使う…") { chooseExistingFile() }
                    Text(AppSettings.shared.customModelPath.isEmpty
                         ? "手元の GGUF を選べます（開発用）。"
                         : AppSettings.shared.customModelPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Text("取得の前に PLaMo Community License を表示して同意を求めます。同意は覚えます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .sheet(item: $model.licenseModel) { entry in
            OnboardingLicenseSheet(model: model, entry: entry)
        }
    }

    private func chooseExistingFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "GGUF のファイルを選ぶ"
        panel.directoryURL = URL(fileURLWithPath: ModelStore.developmentModelPath)
            .deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useExistingFile(url)
    }

    // MARK: 3. 許可

    private var permissionPage: some View {
        pageLayout(
            systemImage: "hand.raised",
            title: "アクセシビリティの許可",
            message: "⌃⌥J で選んだ文を読むために必要です。あとからでもかまいません。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: AccessibilityPermission.isTrusted
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(AccessibilityPermission.isTrusted ? .green : .secondary)
                    Text(AccessibilityPermission.isTrusted ? "許可されています" : "まだ許可されていません")
                        .font(.system(size: 13))
                    Spacer()
                    Button("システム設定を開く") { AccessibilityPermission.openSettings() }
                        .disabled(AccessibilityPermission.isTrusted)
                }
                Text("「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で Perspica を入れます。画面収録の許可は、初めて ⌃⌥O を押したときに聞きます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 4. メニューバー

    private var menuBarPage: some View {
        pageLayout(
            systemImage: "menubar.rectangle",
            title: "メニューバーから使う",
            message: "画面の右上のアイコンが Perspica です。クリックでパネルが開きます。"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                menuBarIllustration
                VStack(alignment: .leading, spacing: 8) {
                    shortcutLine("⌃⌥J", "選んだ文を訳す")
                    shortcutLine("⌃⌥K", "パネルを開く / 閉じる")
                    shortcutLine("⌃⌥O", "画面を翻訳")
                }
            }
        }
    }

    private var menuBarIllustration: some View {
        HStack(spacing: 6) {
            Spacer()
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 220, height: 26)
                .overlay {
                    HStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: "battery.100").font(.system(size: 11)).foregroundStyle(.secondary)
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(width: 22, height: 22)
                            Image(systemName: "character.bubble")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.trailing, 4)
                }
            Text("← ここ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutLine(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Text(text)
                .font(.system(size: 13))
        }
    }

    // MARK: shared page chrome

    private func pageLayout<Content: View>(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        // M5 (SPEC 15): the pages were top-aligned, so a short page left a big
        // empty band under it. Centre the content in the page instead, and
        // still let a taller page scroll.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 19, weight: .semibold))
                            Text(message)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content()
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The licence gate on the onboarding page; the same terms as the manager's.
private struct OnboardingLicenseSheet: View {
    @Bindable var model: ManagerModel
    let entry: TranslationModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PLaMo Community License")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(text)
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

    private var text: String {
        if let url = Bundle.main.url(forResource: "PLAMO-COMMUNITY-LICENSE-en", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return """
        PLaMo Community License Agreement（要点）

        ・個人利用（学習・趣味）と学術利用は、事前の登録なしで無償です。
        ・商用利用は、PFN の登録ページでの事前登録と、年間売上 10 億円以下という条件を
          満たす場合だけ許可されます。
        ・MODEL MATERIALS を第三者に渡すときは、本契約の写しを渡し、「Built with PLaMo」を
          表示し、AI モデル名に「PLaMo」を含める必要があります。
        ・出力は、モデルの出力であることを明示すれば公開できます。
        ・モデルと出力は現状のまま提供され、PFN は保証しません。

        全文: https://plamo.preferredai.jp/info/plamo-community-license-en
        """
    }
}
