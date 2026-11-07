import AppKit
import SwiftUI

/// The accessibility appearance the app draws with.
///
/// Each flag follows the Mac's own setting. A demo launch option can stand in
/// for it, which is how SPEC 15's M5 captures show the reduce-motion,
/// reduce-transparency and increase-contrast looks without changing the Mac's
/// settings (SPEC 18).
@MainActor
enum AppearanceOverrides {
    static var reduceMotionDemo = false
    static var reduceTransparencyDemo = false
    static var increaseContrastDemo = false

    static var reduceMotion: Bool {
        reduceMotionDemo || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool {
        reduceTransparencyDemo || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        increaseContrastDemo || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// The app's Liquid Glass surface.
///
/// With "reduce transparency" on the surface is drawn opaque instead of glass,
/// so the text always sits on a solid colour. With "increase contrast" on, the
/// edge of the surface is drawn stronger. Both read `AppearanceOverrides`, so
/// the demo options cover them too.
struct YakuGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
        let border = AppearanceOverrides.increaseContrast
            ? Color.primary.opacity(0.45)
            : Color.primary.opacity(0.12)

        if AppearanceOverrides.reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.stroke(border, lineWidth: 1) }
        } else {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay {
                    if AppearanceOverrides.increaseContrast {
                        shape.stroke(border, lineWidth: 1)
                    }
                }
        }
    }
}

extension View {
    /// A glass surface that honours the accessibility appearance (SPEC 18).
    func yakuGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(YakuGlass(shape: shape, interactive: interactive))
    }
}
