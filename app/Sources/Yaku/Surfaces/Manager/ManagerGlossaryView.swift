import AppKit
import SwiftUI
import YakuCore

/// 管理画面の「用語集」(SPEC 4.4): the `GlossaryEntry` table with add, delete,
/// enable, reorder (drag) and CSV import/export.
///
/// The table is a `List` of rows rather than SwiftUI's `Table`, because the
/// order matters to the prompt and `List` is what supports drag reordering.
struct ManagerGlossaryView: View {
    @Bindable var model: ManagerModel
    @Bindable var state: ManagerState

    @State private var newSource = ""
    @State private var newTarget = ""

    private static let enabledWidth: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.glossary.isEmpty {
                ManagerPlaceholder(
                    systemImage: "character.book.closed",
                    title: "用語集はまだ空です",
                    message: "「固有名詞を訳さない」などの決まりを足せます。"
                )
            } else {
                table
            }
            Divider()
            footer
        }
        .navigationTitle("用語集")
        .toolbar { toolbarContent }
        .onAppear { model.reloadGlossary() }
    }

    // MARK: header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Text("有効").frame(width: Self.enabledWidth, alignment: .leading)
            Text("原語").frame(maxWidth: .infinity, alignment: .leading)
            Text("訳語").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: Design.Font.caption, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("原語", text: $newSource)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            TextField("訳語", text: $newTarget)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button("追加") {
                model.addGlossaryEntry(source: newSource, target: newTarget)
                newSource = ""
                newTarget = ""
            }
            .disabled(newSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            Text("有効な項目のうち原文に現れるものが訳に渡されます。")
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.m)
    }

    // MARK: table

    private var table: some View {
        List(selection: $model.selectedGlossary) {
            ForEach(model.glossary) { entry in
                row(entry)
                    .tag(entry.persistentModelID)
            }
            .onMove { indices, destination in
                model.moveGlossary(from: indices, to: destination)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, Design.rowMinHeight)
    }

    private func row(_ entry: GlossaryEntry) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { model.setGlossaryEnabled(entry, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.enabledWidth, alignment: .leading)

            TextField("", text: Binding(
                get: { entry.source },
                set: { entry.source = $0; model.glossaryEdited() }
            ))
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("", text: Binding(
                get: { entry.target },
                set: { entry.target = $0; model.glossaryEdited() }
            ))
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.deleteGlossary(model.selectedEntries())
            } label: {
                Label("削除", systemImage: "minus")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.selectedGlossary.isEmpty)

            // the two arrows looked alike. Each now carries the word it
            // does, so 読み込む and 書き出す cannot be mixed up.
            Button {
                importCSV()
            } label: {
                Label("読み込む", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("用語集の CSV を読み込む")

            Button {
                exportCSV()
            } label: {
                Label("書き出す", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .help("用語集を CSV に書き出す")
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "用語集の CSV を選ぶ（source,target,enabled）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importGlossary(from: url)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "glossary.csv"
        panel.message = "用語集を CSV に書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportGlossary(to: url)
    }
}
