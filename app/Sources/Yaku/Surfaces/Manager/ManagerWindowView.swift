import SwiftUI
import YakuCore

/// The manager window (SPEC 4.4): one `Window` scene with a standard
/// `NavigationSplitView`, so the sidebar and the toolbar get macOS 26's own
/// Liquid Glass rather than anything drawn here.
struct ManagerWindowView: View {
    @Bindable var coordinator: TranslationCoordinator
    @Bindable var model: ManagerModel
    @Bindable var pdf: PDFQueue
    @Bindable var state: ManagerState
    var onChoosePDF: () -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(WindowProbe { window in
            WindowBridge.shared.adopt(openWindow: openWindow, openSettings: openSettings)
            WindowActivation.shared.activate(window)
        })
        .onAppear {
            WindowBridge.shared.adopt(openWindow: openWindow, openSettings: openSettings)
            model.reloadHistory()
            model.reloadGlossary()
            model.refreshInstalled()
            AppLog.write("manager: appeared on \(state.section.rawValue)")
        }
        .onDisappear {
            // The window closed: give the run loop a turn so the window is
            // really gone, then drop the Dock icon if nothing else is open.
            DispatchQueue.main.async {
                WindowActivation.shared.windowDidDisappear()
            }
        }
    }

    // MARK: sidebar

    private var selection: Binding<ManagerSection?> {
        Binding(
            get: { state.section },
            set: { if let new = $0 { state.select(new) } }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(ManagerSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        // M7: the system's own sidebar material and selection, so the selected
        // row is macOS 26's rounded accent row rather than a flat highlight.
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
        .safeAreaInset(edge: .bottom) {
            engineFooter
        }
    }

    private var engineFooter: some View {
        HStack(spacing: Design.Space.s) {
            Circle()
                .fill(engineTone)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("エンジン")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.engineStatusText)
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
    }

    /// The footer's dot: the same state word the text shows, in one colour.
    private var engineTone: Color {
        switch model.engine.state {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .translate:
            ManagerTranslateView(coordinator: coordinator, model: model)
        case .pdf:
            ManagerPDFView(pdf: pdf, onChoosePDF: onChoosePDF)
        case .history:
            ManagerHistoryView(coordinator: coordinator, model: model, state: state)
        case .glossary:
            ManagerGlossaryView(model: model, state: state)
        case .models:
            ManagerModelsView(model: model)
        }
    }
}
