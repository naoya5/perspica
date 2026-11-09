import SwiftUI

/// The black island: flush with the screen top, concave "ears" at the two top
/// corners, and continuous-curvature (squircle) corners at the bottom.
///
/// Moved from an earlier prototype, where the shape was
/// tuned against the real screen.
/// `earRadius` is supplied by `NotchModel`, which grows it with the island so
/// the ears do not read as small black bumps (SPEC 4.5). The result still needs
/// one look on an unlocked screen.
struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    /// Radius of the reverse-rounded ears at the top corners.
    var earRadius: CGFloat = 6
    /// Superellipse exponent for the bottom corners. 4.6 is close to Apple's squircle.
    var squirclePower: CGFloat = 4.6

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), cornerRadius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(width, 1)
        let h = max(height, 1)
        let e = min(earRadius, min(w / 2, h / 2))
        let r = min(cornerRadius, min(w / 2, h - e))

        var path = Path()
        // Top edge, between the two reverse-rounded ears.
        path.move(to: CGPoint(x: e, y: 0))
        path.addLine(to: CGPoint(x: w - e, y: 0))
        // Right ear: concave fillet blending into the screen edge.
        path.addQuadCurve(to: CGPoint(x: w, y: e), control: CGPoint(x: w - e, y: e))
        path.addLine(to: CGPoint(x: w, y: h - r))
        addBottomRightCorner(to: &path, x0: w - r, y0: h - r, r: r)
        path.addLine(to: CGPoint(x: r, y: h))
        addBottomLeftCorner(to: &path, x0: r, y0: h - r, r: r)
        path.addLine(to: CGPoint(x: 0, y: e))
        path.addQuadCurve(to: CGPoint(x: e, y: 0), control: CGPoint(x: e, y: e))
        path.closeSubpath()
        return path
    }

    /// From (x0, y0 + r) to (x0 - r, y0); x0,y0 is the corner centre.
    private func addBottomLeftCorner(to path: inout Path, x0: CGFloat, y0: CGFloat, r: CGFloat) {
        guard r > 0.01 else { path.addLine(to: CGPoint(x: x0, y: y0 + r)); return }
        let n = squirclePower
        let steps = 24
        for index in 1...steps {
            let t = Double(index) / Double(steps) * (Double.pi / 2)
            let u = CGFloat(-pow(sin(t), 2 / n))
            let v = CGFloat(pow(cos(t), 2 / n))
            path.addLine(to: CGPoint(x: x0 + r * u, y: y0 + r * v))
        }
    }

    /// From (x0 + r, y0) to (x0, y0 + r); x0,y0 is the corner centre.
    private func addBottomRightCorner(to path: inout Path, x0: CGFloat, y0: CGFloat, r: CGFloat) {
        guard r > 0.01 else { path.addLine(to: CGPoint(x: x0 + r, y: y0)); return }
        let n = squirclePower
        let steps = 24
        for index in 1...steps {
            let t = Double(index) / Double(steps) * (Double.pi / 2)
            let u = CGFloat(pow(cos(t), 2 / n))
            let v = CGFloat(pow(sin(t), 2 / n))
            path.addLine(to: CGPoint(x: x0 + r * u, y: y0 + r * v))
        }
    }
}

/// Only the bottom edge (with the two squircle corners), used for the 1px rim
/// that appears while the island is open.
struct NotchBottomEdge: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var squirclePower: CGFloat = 4.6
    var insetY: CGFloat = 0.5

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), cornerRadius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(width, 1)
        let h = max(height, 1)
        let r = min(cornerRadius, min(w / 2, h))
        let y = h - insetY
        let n = squirclePower
        let steps = 24

        var path = Path()
        path.move(to: CGPoint(x: 0, y: y - r))
        for index in 1...steps {
            let t = Double(index) / Double(steps) * (Double.pi / 2)
            let u = -pow(cos(t), 2 / n)
            let v = pow(sin(t), 2 / n)
            path.addLine(to: CGPoint(x: r + r * CGFloat(u), y: (y - r) + r * CGFloat(v)))
        }
        path.addLine(to: CGPoint(x: w - r, y: y))
        for index in 1...steps {
            let t = Double(index) / Double(steps) * (Double.pi / 2)
            let u = pow(sin(t), 2 / n)
            let v = pow(cos(t), 2 / n)
            path.addLine(to: CGPoint(x: (w - r) + r * CGFloat(u), y: (y - r) + r * CGFloat(v)))
        }
        return path
    }
}

/// Shape that always fills the rect it is given (used for clipping and the
/// glow, so they follow the animated frame).
struct NotchShapeFit: Shape {
    var cornerRadius: CGFloat
    var earRadius: CGFloat = 6

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        NotchShape(
            width: rect.width,
            height: rect.height,
            cornerRadius: cornerRadius,
            earRadius: earRadius
        ).path(in: rect)
    }
}
