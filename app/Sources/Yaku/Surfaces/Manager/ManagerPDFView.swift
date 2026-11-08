import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import YakuCore

/// 管理画面の「PDF」(SPEC 4.4): a drop well on top and the list of jobs below,
/// with a thumbnail, the name, the page count, the state and how long it took.
struct ManagerPDFView: View {
    @Bindable var pdf: PDFQueue
    var onChoosePDF: () -> Void

    @State private var dropHover = false
    @State private var thumbnails: [UUID: NSImage] = [:]
    /// Which job's full error message is open in the 詳細 popover (M7 9).
    @State private var errorJobID: UUID?
    @State private var errorJobMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            dropWell
            Divider()
            if pdf.jobs.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("PDF")
    }

    // MARK: drop well

    private var dropWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.Radius.well, style: .continuous)
                .fill(dropHover ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary))
            // M7 9: a dashed edge that becomes a solid accent edge while a file
            // is over it, so the drop target is unmistakable.
            RoundedRectangle(cornerRadius: Design.Radius.well, style: .continuous)
                .strokeBorder(
                    dropHover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: dropHover ? 2 : 1, dash: dropHover ? [] : [6, 4])
                )
            VStack(spacing: Design.Space.s) {
                Image(systemName: dropHover ? "arrow.down.doc.fill" : "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(dropHover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text(dropHover ? "ここにドロップ" : "PDF をドロップして日本語に")
                    .font(.system(size: Design.Font.body, weight: dropHover ? .semibold : .regular))
                    .foregroundStyle(dropHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("レイアウトはそのまま")
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.tertiary)
                Button("PDF を開く…") { onChoosePDF() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(height: 150)
        .padding(Design.pagePadding)
        .scaleEffect(dropHover ? 1.02 : 1.0)
        .animation(.snappy(duration: 0.25), value: dropHover)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropHover) { providers in
            handleDrop(providers)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Design.Space.m) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("まだ PDF を訳していません")
                .font(.system(size: Design.Font.body))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The full failure text, one line in the row and everything here (M7 9).
    private var errorDetail: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("失敗の詳細")
                .font(.system(size: Design.Font.label, weight: .semibold))
            ScrollView {
                Text(errorJobMessage)
                    .font(.system(size: Design.Font.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("閉じる") { errorJobID = nil }
            }
        }
        .padding(Design.Space.l)
        .frame(width: 420)
    }

    // MARK: list

    private var list: some View {
        List {
            ForEach(pdf.jobs, id: \.id) { job in
                row(job)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ job: PDFJob) -> some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            thumbnail(for: job)
                .frame(width: 34, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName)
                    .font(.system(size: Design.Font.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Design.Space.s) {
                    Text("\(job.pageCount) ページ")
                    Text(job.jobState.japaneseName)
                        .foregroundStyle(stateColor(job))
                    if job.jobState == .running || job.jobState == .queued {
                        Text(PDFStage.japaneseName(for: job.stage))
                    }
                    if job.seconds > 0 {
                        Text(String(format: "%.1f 秒", job.seconds))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: Design.Font.caption))
                .foregroundStyle(.secondary)

                if job.jobState == .running {
                    ProgressView(value: job.progress)
                        .frame(maxWidth: 260)
                }
                if job.jobState == .failed, !job.errorMessage.isEmpty {
                    // M7 9: one line in the row; the whole message is in 詳細.
                    HStack(spacing: Design.Space.s) {
                        Text(job.errorMessage)
                            .font(.system(size: Design.Font.caption))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("詳細") {
                            errorJobMessage = job.errorMessage
                            errorJobID = job.id
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .popover(isPresented: Binding(
                            get: { errorJobID == job.id },
                            set: { if !$0 { errorJobID = nil } }
                        ), arrowEdge: .bottom) {
                            errorDetail
                        }
                    }
                }
            }

            Spacer(minLength: Design.Space.s)

            actions(job)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Finder で表示") { pdf.revealOutput(job) }
                .disabled(job.outputMonoPath.isEmpty && job.outputDualPath.isEmpty)
            Divider()
            Button("一覧から消す", role: .destructive) { pdf.delete(job) }
                .disabled(job.id == pdf.runningID)
        }
        .task(id: job.id) { await loadThumbnail(for: job) }
    }

    @ViewBuilder
    private func actions(_ job: PDFJob) -> some View {
        HStack(spacing: 6) {
            switch job.jobState {
            case .done:
                Button("開く") { pdf.openOutput(job) }
                    .controlSize(.small)
                Button("対訳版") { pdf.openOutput(job, dual: true) }
                    .controlSize(.small)
                    .disabled(job.outputDualPath.isEmpty)
                Button("Finder で表示") { pdf.revealOutput(job) }
                    .controlSize(.small)
            case .running, .queued:
                Button("取り消し") { pdf.cancel(job) }
                    .controlSize(.small)
            case .failed, .cancelled:
                Button("もう一度") { pdf.retry(job) }
                    .controlSize(.small)
            }
        }
    }

    private func stateColor(_ job: PDFJob) -> Color {
        switch job.jobState {
        case .done: .green
        case .failed: .red
        default: .secondary
        }
    }

    // MARK: thumbnails

    @ViewBuilder
    private func thumbnail(for job: PDFJob) -> some View {
        if let image = thumbnails[job.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    /// SPEC 4.4: サムネイルは QuickLookThumbnailing. The async form runs inside
    /// the row's `.task(id:)`, so it lives as long as the row. The generator does
    /// not stop when cancelled, so a row that went away drops the result.
    private func loadThumbnail(for job: PDFJob) async {
        guard thumbnails[job.id] == nil, let url = PDFIntake.resolve(job.inputBookmark) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 68, height: 88),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled
        else { return }
        thumbnails[job.id] = representation.nsImage
    }

    // MARK: drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in _ = pdf.enqueue(url: url) }
        }
        return true
    }
}
