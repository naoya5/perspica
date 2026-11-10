import AppKit
import QuartzCore

/// The processing light (SPEC 6.5) drawn with Core Animation rather than a
/// SwiftUI `TimelineView`.
///
/// A `TimelineView` inside the panel's `NSHostingView` made the hosting view
/// re-render on every tick, which measured 9–13% CPU on its own (a bare
/// `TimelineView` returning `Color.clear` cost 9.2%). The light is only an
/// outline, so it belongs on a GPU-composited layer: a conic gradient masked by
/// a rounded-rect stroke, with the gradient rotating and the mask fixed.
///
/// The 18px halo from SPEC 6.5 is approximated by four concentric strokes of
/// decreasing opacity. A real gaussian blur would have to run per frame and
/// would put the cost back where it was.
final class GlowLayerView: NSView {
    /// (line width, opacity) from the crisp edge outwards. Many thin rings with
    /// a smooth falloff stand in for SPEC 6.5's 18px blur at 35%: a real blur
    /// would have to run every frame and would cost what the SwiftUI timeline
    /// cost. The total is tuned so the outermost rings land near 35% at 18px.
    private static let rings: [(width: CGFloat, opacity: CGFloat)] = [
        (1.5, 1.00),
        (4, 0.26),
        (7, 0.17),
        (10, 0.12),
        (13, 0.09),
        (16, 0.06),
        (19, 0.04),
        (22, 0.02),
    ]

    /// SPEC 6.2's palette, closing on the first colour so the sweep wraps.
    private static let colors: [CGColor] = [0x4F8CFF, 0xB36BFF, 0xFF6FB1, 0xFFB35C, 0x4F8CFF]
        .map { hex -> CGColor in
            let red = CGFloat((hex >> 16) & 0xFF) / 255
            let green = CGFloat((hex >> 8) & 0xFF) / 255
            let blue = CGFloat(hex & 0xFF) / 255
            return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

    private var containers: [CALayer] = []
    private var gradients: [CAGradientLayer] = []
    private var masks: [CAShapeLayer] = []

    private var cornerRadius: CGFloat = 24
    private var cycleSeconds: Double = 2.4
    private var reduceMotion = false
    private(set) var isGlowing = false

    private static let rotationKey = "yaku.glow.rotation"
    private static let pulseKey = "yaku.glow.pulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setUpLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GlowLayerView does not support NSCoder")
    }

    /// Never takes a click; the shape's own views handle input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func setUpLayers() {
        guard let host = layer else { return }
        for ring in Self.rings {
            // The gradient rotates; the shape it is clipped to must not. The
            // mask therefore lives on a fixed container and the gradient is a
            // child of it — an earlier version masked the gradient directly, so
            // the mask turned with it and the light swept out as a rotating
            // square instead of staying on the panel's edge.
            let container = CALayer()
            container.opacity = 0

            let mask = CAShapeLayer()
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 1, alpha: 1)
            mask.lineWidth = ring.width
            container.mask = mask

            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.colors = Self.colors
            gradient.locations = [0, 0.25, 0.5, 0.75, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            container.addSublayer(gradient)

            host.addSublayer(container)
            containers.append(container)
            gradients.append(gradient)
            masks.append(mask)
        }
    }

    /// Applies the current state. `active` fades the light in or out; the other
    /// values are only read while it is on.
    func configure(active: Bool, cornerRadius: CGFloat, cycleSeconds: Double, reduceMotion: Bool) {
        let radiusChanged = cornerRadius != self.cornerRadius
        let animationChanged = cycleSeconds != self.cycleSeconds || reduceMotion != self.reduceMotion
        self.cornerRadius = cornerRadius
        self.cycleSeconds = cycleSeconds
        self.reduceMotion = reduceMotion

        if radiusChanged { needsLayout = true }

        guard active != isGlowing else {
            if active && animationChanged { updateAnimations() }
            return
        }
        isGlowing = active
        if active {
            // The glow only exists while there is work to show.
            isHidden = false
            updateAnimations()
            setAlpha(1, duration: 0.15, timing: .easeIn)
        } else {
            setAlpha(0, duration: 0.4, timing: .easeOut)
            removeAnimations()
        }
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // The shape's height animates in SwiftUI over 0.16s; the mask paths and
        // frames animate with it so the light does not jump as text arrives.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, gradient) in gradients.enumerated() {
            let container = containers[index]
            container.frame = bounds
            let inset = Self.rings[index].width / 2
            masks[index].frame = bounds
            masks[index].path = CGPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerWidth: max(cornerRadius - inset, 0),
                cornerHeight: max(cornerRadius - inset, 0),
                transform: nil
            )
            // The rotating gradient must cover the container at every angle, so
            // it is a square as wide as the container's diagonal.
            let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() * 1.05
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            container.opacity = isGlowing ? Float(Self.rings[index].opacity) : 0
        }
        CATransaction.commit()
    }

    private func updateAnimations() {
        needsLayout = true

        for gradient in gradients {
            if reduceMotion {
                gradient.removeAnimation(forKey: Self.rotationKey)
                gradient.transform = CATransform3DIdentity
            } else {
                gradient.removeAnimation(forKey: Self.rotationKey)
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0
                rotation.toValue = 2 * Double.pi
                rotation.duration = cycleSeconds
                rotation.repeatCount = .infinity
                rotation.timingFunction = CAMediaTimingFunction(name: .linear)
                gradient.add(rotation, forKey: Self.rotationKey)
            }
        }

        if reduceMotion {
            // Reduce motion: no rotation, only a change in brightness (SPEC 6.5).
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.75
            pulse.toValue = 1.0
            pulse.duration = 1.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: Self.pulseKey)
        } else {
            layer?.removeAnimation(forKey: Self.pulseKey)
        }
    }

    private func removeAnimations() {
        for gradient in gradients {
            gradient.removeAnimation(forKey: Self.rotationKey)
            gradient.transform = CATransform3DIdentity
        }
        layer?.removeAnimation(forKey: Self.pulseKey)
    }

    private func setAlpha(_ alpha: Float, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = alpha
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.opacity = alpha
        layer.add(animation, forKey: "yaku.glow.fade")
    }

}
