import SwiftUI

/// The island's content (SPEC 4.5).
///
/// The window is a fixed transparent canvas; only the black shape inside it
/// changes size, which is what keeps the animation smooth (notch-app SPEC 2).
struct NotchRootView: View {
    @Bindable var model: NotchModel
    var onOpen: (_ dual: Bool) -> Void
    var onReveal: () -> Void
    var onShowLog: () -> Void
    var onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            island
        }
        .frame(width: 640, height: 520, alignment: .top)
    }

    private var spring: Animation {
        AppearanceOverrides.reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.80)
    }

    private var island: some View {
        let size = model.islandSize
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Button { model.toggleExpanded() } label: {
                    NotchShape(
                        width: size.width,
                        height: size.height,
                        cornerRadius: model.cornerRadius,
                        earRadius: model.earRadius
                    )
                    .fill(Color.black)
                    .contentShape(NotchShapeFit(cornerRadius: model.cornerRadius, earRadius: model.earRadius))
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel("PDF の詳細を開く・閉じる")
                .help("PDF の詳細を開く・閉じる")

                if model.expanded {
                    NotchBottomEdge(
                        width: size.width,
                        height: size.height,
                        cornerRadius: model.cornerRadius
                    )
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
                }

                content
            }
            .clipShape(NotchShapeFit(cornerRadius: model.cornerRadius, earRadius: model.earRadius))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(AppearanceOverrides.reduceMotion ? nil : spring, value: model.islandSize)
        .animation(AppearanceOverrides.reduceMotion ? nil : spring, value: model.expanded)
        .modifier(ShakeEffect(travel: 5, shakes: model.dropShake))
        // The island has no title of its own, so VoiceOver is given the state
        // as a name (SPEC 18). The expanded buttons keep their own names.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilitySummary)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .closed:
            EmptyView()
        case .drop:
            dropContent
        case .activity:
            if model.expanded { activityExpanded } else { activityCompact }
        case .done:
            if model.expanded { doneExpanded } else { statusCompact(done: true) }
        case .error:
            if model.expanded { errorExpanded } else { statusCompact(done: false) }
        }
    }

    // MARK: drop

    private var dropContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(model.dropMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.80))
                Text("レイアウトはそのまま")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(16)
        .scaleEffect(model.dropHover && !AppearanceOverrides.reduceMotion ? 1.02 : 1.0)
        .animation(spring, value: model.dropHover)
        .frame(width: model.islandSize.width, height: model.islandSize.height)
    }

    // MARK: activity

    private var activityCompact: some View {
        HStack(spacing: 0) {
            ZStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Circle()
                    .trim(from: 0, to: max(0.02, model.progress))
                    .stroke(
                        LinearGradient(
                            colors: Palette.glow,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
            }
            .frame(width: 28, height: 28)

            Spacer(minLength: 0)

            Text(model.progressText)
                .font(.system(size: 11))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .frame(width: model.islandSize.width, height: model.islandSize.height)
    }

    private var activityExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.fileName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.stageJapanese)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.60))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: Palette.glow, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geometry.size.width * model.progress))
                }
            }
            .frame(height: 4)

            HStack {
                Text(model.elapsedText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                Text(model.progressText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, model.notchSize.height + 10)
        .padding(.bottom, 16)
        .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
    }

    // MARK: done / error

    private func statusCompact(done: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(done ? Color(hex: 0x4ADE80) : Color(hex: 0xFF6B6B))
                .modifier(DonePop(active: done))
            Spacer(minLength: 0)
            if done {
                Text("完了")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: model.islandSize.width, height: model.islandSize.height)
    }

    private var doneExpanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0x4ADE80))
                Text(model.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(model.elapsedText) で訳しました")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))

            HStack(spacing: 8) {
                islandButton("開く") { onOpen(false) }
                    .disabled(model.monoPath.isEmpty)
                islandButton("対訳版") { onOpen(true) }
                    .disabled(model.dualPath.isEmpty)
                islandButton("Finder で表示") { onReveal() }
                    .disabled(model.monoPath.isEmpty && model.dualPath.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, model.notchSize.height + 10)
        .padding(.bottom, 16)
        .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
    }

    private var errorExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                Text(model.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(model.errorMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                islandButton("もう一度") { onRetry() }
                islandButton("ログを見る") { onShowLog() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, model.notchSize.height + 10)
        .padding(.bottom, 16)
        .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
    }

    private func islandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.white.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
        .focusable()
    }
}

/// The one-off pop on the green checkmark (SPEC 4.5: 右で緑の checkmark.circle.fill が弾む).
private struct DonePop: ViewModifier {
    var active: Bool
    @State private var popped = false

    /// `.task(id:)` runs on appear and again when `active` changes, and SwiftUI
    /// cancels the wait if the mark leaves before it settles back.
    func body(content: Content) -> some View {
        content
            .scaleEffect(popped ? 1.25 : 1.0)
            .task(id: active) {
                guard active, !AppearanceOverrides.reduceMotion else {
                    popped = false
                    return
                }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.5)) { popped = true }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { popped = false }
            }
    }
}
