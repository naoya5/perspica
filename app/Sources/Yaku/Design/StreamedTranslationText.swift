import SwiftUI

/// Keep the 30 Hz reveal observation in the text leaf, not the glass surface.
struct StreamedTranslationText: View {
    var state: TranslationCoordinator.SurfaceState
    var visible: Bool
    var showSource = false
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    @State private var reveal = TextRevealDriver()

    var body: some View {
        Text(showSource ? state.sourceText : state.translation)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .textRenderer(FadeInTextRenderer(revealed: showSource ? Double(state.sourceText.count) : reveal.revealed))
            .textSelection(.enabled)
            .onAppear { reveal.finish(to: state.translation.count) }
            .onChange(of: state.translation) { _, text in
                if visible { reveal.update(count: text.count) }
                else { reveal.finish(to: text.count) }
            }
            .onChange(of: visible) { _, _ in
                reveal.finish(to: state.translation.count)
            }
            .onDisappear { reveal.stop() }
    }
}
