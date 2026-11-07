import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The colours the app uses itself. Everything else comes from the system's
/// semantic colours (SPEC 6.2); only the processing light has its own palette.
enum Palette {
    /// SPEC 6.2: #4F8CFF → #B36BFF → #FF6FB1 → #FFB35C → #4F8CFF.
    static let glow: [Color] = [
        Color(hex: 0x4F8CFF),
        Color(hex: 0xB36BFF),
        Color(hex: 0xFF6FB1),
        Color(hex: 0xFFB35C),
        Color(hex: 0x4F8CFF),
    ]

    static func angular(angle: Double) -> AngularGradient {
        AngularGradient(
            colors: glow,
            center: .center,
            startAngle: .degrees(angle),
            endAngle: .degrees(angle + 360)
        )
    }
}
