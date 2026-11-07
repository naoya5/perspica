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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary)
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text(dropHover ? "ここにドロップ" : "PDF をドロップして日本語に")
                    .font(.system(size: 13))
                    .foregroundStyle(dropHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("レイアウトはそのまま")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button("PDF を開く…") { onChoosePDF() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(height: 150)
        .padding(20)
        .scaleEffect(dropHover ? 1.01 : 1.0)
        .animation(.snappy(duration: 0.25), value: dropHover)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropHover) { providers in
            handleDrop(providers)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("まだ PDF を訳していません")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(alignment: .center, spacing: 12) {
            thumbnail(for: job)
                .frame(width: 34, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                if job.jobState == .running {
                    ProgressView(value: job.progress)
                        .frame(maxWidth: 260)
                }
                if job.jobState == .failed, !job.errorMessage.isEmpty {
                    Text(job.errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

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
        .task(id: job.id) { generateThumbnail(for: job) }
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

    /// SPEC 4.4: サムネイルは QuickLookThumbnailing.
    private func generateThumbnail(for job: PDFJob) {
        guard thumbnails[job.id] == nil, let url = PDFIntake.resolve(job.inputBookmark) else { return }
        let id = job.id
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 68, height: 88),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let representation else { return }
            let image = representation.nsImage
            Task { @MainActor in thumbnails[id] = image }
        }
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
