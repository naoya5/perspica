import SwiftUI

/// One small horizontal shake for a refused drop (SPEC 4.2, 4.5).
///
/// The offset is `sin(2π · shakes)`, which is zero at every whole number. Add
/// 1 to `shakes` inside `withAnimation` and the view shakes once and ends where
/// it started, so nothing has to set it back. A second refusal adds 1 again and
/// shakes again, even if the first shake has not finished.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 2), y: 0))
    }
}
