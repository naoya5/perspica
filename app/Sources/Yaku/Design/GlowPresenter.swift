import AppKit
import Observation

/// Keeps a `GlowLayerView` in step with the translation state.
///
/// The glow is a plain `NSView` sibling of the SwiftUI hosting view, so the
/// SwiftUI tree never re-renders for the animation (see `GlowLayerView`).
/// `withObservationTracking` re-arms itself after every change.
@MainActor
final class GlowPresenter {
    let view = GlowLayerView()

    private let cornerRadius: CGFloat
    private let shapeRect: () -> CGRect
    private let phase: () -> TranslationCoordinator.Phase
    private let isOpen: () -> Bool

    init(
        cornerRadius: CGFloat,
        shapeRect: @escaping () -> CGRect,
        phase: @escaping () -> TranslationCoordinator.Phase,
        isOpen: @escaping () -> Bool
    ) {
        self.cornerRadius = cornerRadius
        self.shapeRect = shapeRect
        self.phase = phase
        self.isOpen = isOpen
    }

    func start() {
        observe()
    }

    private func observe() {
        withObservationTracking {
            apply(phase: phase(), rect: shapeRect(), open: isOpen())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func apply(phase: TranslationCoordinator.Phase, rect: CGRect, open: Bool) {
        let active: Bool
        let cycle: Double
        switch phase {
        case .preparing:
            active = true
            cycle = 4
        case .translating:
            active = true
            cycle = 2.4
        case .empty, .done, .failed:
            active = false
            cycle = 2.4
        }

        view.frame = rect
        view.configure(
            active: active && open,
            cornerRadius: cornerRadius,
            cycleSeconds: cycle,
            reduceMotion: AppearanceOverrides.reduceMotion
        )
    }
}
