import SwiftUI
import YakuCore

/// 管理画面の「履歴」(SPEC 4.4): a searchable list on the left, the full text on
/// the right, with copy, delete and 「用語集に足す」.
struct ManagerHistoryView: View {
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var model: ManagerModel
    @Bindable var state: ManagerState

    var body: some View {
        // Not HSplitView: inside NavigationSplitView it ignored the floating
        // sidebar's inset, squeezed the sidebar and pushed the detail about
        // 15 pt past the window's right edge (M7 review).
        HStack(spacing: 0) {
            list
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("履歴")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.glossaryDraftSource = model.selectedHistory?.source ?? ""
                    state.glossaryDraftTarget = model.selectedHistory?.target ?? ""
                    state.showsGlossaryDraft = true
                } label: {
                    Label("用語集に足す", systemImage: "character.book.closed")
                }
                .disabled(model.selectedHistory == nil)
                .help("原文と訳文の一部を用語集に足す")

                Button(role: .destructive) {
                    if let item = model.selectedHistory { model.deleteHistory([item]) }
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(model.selectedHistory == nil)
            }
        }
        .sheet(isPresented: $state.showsGlossaryDraft) {
            GlossaryDraftSheet(coordinator: coordinator, state: state)
        }
        .onAppear { model.reloadHistory() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("検索", text: $model.historySearch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if model.history.isEmpty {
                ManagerPlaceholder(
                    systemImage: "clock",
                    title: "まだ翻訳した文はありません",
                    message: model.historySearch.isEmpty
                        ? "パネルや HUD で訳した文がここにたまります。"
                        : "「\(model.historySearch)」に合う履歴はありません。"
                )
            } else {
                List(model.history, selection: Binding(
                    get: { model.selectedHistory?.persistentModelID },
                    set: { id in
                        model.selectedHistory = model.history.first { $0.persistentModelID == id }
                    }
                )) { item in
                    row(item)
                        .tag(item.persistentModelID)
                }
            }
        }
        .frame(width: 320)
    }

    private func row(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: originSymbol(item.origin))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                // M7 6: the direction of the pair, then how long ago.
                DesignLanguageDirection(source: item.sourceLanguage, target: item.targetLanguage)
                Spacer(minLength: Design.Space.xs)
                Text(RelativeTime.text(for: item.date))
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(item.source.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: Design.Font.body))
                .lineLimit(1)
            Text(item.target.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: Design.Font.body))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private func originSymbol(_ origin: String) -> String {
        switch origin {
        case "hud": "text.cursor"
        case "manager": "macwindow"
        case "overlay": "text.viewfinder"
        case "pdf": "doc.text"
        default: "menubar.rectangle"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedHistory {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    HStack(spacing: Design.Space.s) {
                        DesignLanguageDirection(source: item.sourceLanguage, target: item.targetLanguage)
                        Spacer(minLength: Design.Space.s)
                        Text(item.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    field("原文", item.source, language: item.sourceLanguage)
                    field("訳文", item.target, language: item.targetLanguage)
                    HStack(spacing: Design.Space.s) {
                        Button("訳文をコピー") { model.copy(item.target) }
                        Button("原文をコピー") { model.copy(item.source) }
                        Spacer(minLength: Design.Space.s)
                        Text(String(format: "%@ · %.2f 秒",
                                    item.frontApp.isEmpty ? "—" : item.frontApp,
                                    item.seconds))
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(Design.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 320)
        } else {
            ManagerPlaceholder(
                systemImage: "clock",
                title: "履歴を選んでください",
                message: "左の一覧から選ぶと、ここに全文が出ます。"
            )
            .frame(minWidth: 320)
        }
    }

    private func field(_ title: String, _ text: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.s) {
                ManagerSectionLabel(text: title)
                Text(LanguageCatalog.name(for: language))
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: title == "訳文" ? Design.Font.translation : 14))
                .lineSpacing(title == "訳文" ? 8.5 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .designCard(padding: Design.Space.m)
        }
    }
}

/// 「用語集に足す」: the source and the translation, trimmed by hand to the part
/// worth keeping (SPEC 4.4).
private struct GlossaryDraftSheet: View {
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var state: ManagerState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用語集に足す")
                .font(.system(size: 15, weight: .semibold))
            Text("足したい部分だけを残して、原語と訳語を整えてください。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ManagerSectionLabel(text: "原語")
            TextEditor(text: $state.glossaryDraftSource)
                .font(.system(size: 13))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            ManagerSectionLabel(text: "訳語")
            TextEditor(text: $state.glossaryDraftTarget)
                .font(.system(size: 13))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button("やめる") { dismiss() }
                Button("足す") {
                    coordinator.addGlossaryEntry(
                        source: state.glossaryDraftSource,
                        target: state.glossaryDraftTarget
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.glossaryDraftSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
