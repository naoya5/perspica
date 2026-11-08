import SwiftUI
import YakuCore

/// The look the settings and manager windows share (M7).
///
/// The panel, the HUD, the overlay and the island keep their own numbers in
/// `PanelLayout` / `HUDLayout`; those surfaces are glass over the screen and
/// are deliberately not touched here. These are the two hand-opened windows,
/// which read as ordinary macOS 26 windows: a grouped form, a sidebar, cards
/// made of the system's own `quaternary` fill (SPEC 6.1: no glass on a large
/// surface, that is the system's job).
///
/// Everything is a multiple of 4 and every corner is continuous (SPEC 6.4).
enum Design {
    /// Spacing (SPEC 6.4: 4 の倍数).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// Continuous corner radii (SPEC 6.4).
    enum Radius {
        /// A card or a well.
        static let card: CGFloat = 12
        /// The PDF drop well, which is a little rounder than a card.
        static let well: CGFloat = 16
        /// A small field or a badge's own rectangle.
        static let field: CGFloat = 8
    }

    /// Type sizes (SPEC 6.3): 11–12 for the supporting text, 13 for a control
    /// label, 15 for a section title, 17 for the manager's translation.
    enum Font {
        static let caption: CGFloat = 11
        static let label: CGFloat = 12
        static let body: CGFloat = 13
        static let sectionTitle: CGFloat = 15
        static let translation: CGFloat = 17
    }

    /// The padding a manager page gets from the window edge.
    static let pagePadding: CGFloat = Design.Space.xl
    /// The height of a manager list row, so the history and the glossary read
    /// as the same kind of list.
    static let rowMinHeight: CGFloat = 28
}

// MARK: - card

/// A card: the shared surface of the settings and manager windows.
///
/// The fill is the system's `quaternary`, not a colour of our own, so light and
/// dark come out right without a second palette (SPEC 6.2). With "increase
/// contrast" on, a hairline edge is added, the same way `YakuGlass` does for
/// the panel (SPEC 18).
struct DesignCard: ViewModifier {
    var padding: CGFloat = Design.Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.5),
                in: .rect(cornerRadius: Design.Radius.card, style: .continuous)
            )
            .overlay {
                if AppearanceOverrides.increaseContrast {
                    RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                }
            }
    }
}

extension View {
    /// Wrap the content in the shared card surface (M7).
    func designCard(padding: CGFloat = Design.Space.l) -> some View {
        modifier(DesignCard(padding: padding))
    }
}

// MARK: - section

/// A section heading for the manager's scrolling pages, so a card is never a
/// floating rectangle (M7 2). It reads like the settings form's own section
/// header: a small semibold caption in the secondary colour, an optional
/// one-line explanation under it, then the content.
struct DesignSection<Content: View>: View {
    var title: String
    var note: String?
    @ViewBuilder var content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Design.Font.label, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let note {
                    Text(note)
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

// MARK: - badge

/// One status pill, used wherever a state is shown as a short word (M7 8):
/// 「使用中」「取得済み」「取得中 42%」「未取得」 on the model cards. The tone
/// picks the colour; the icon is optional.
struct DesignBadge: View {
    enum Tone {
        case neutral, accent, success, warning, failure
    }

    var text: String
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    // Decorative: the word carries the meaning, and keeping the
                    // icon out of the accessibility tree leaves the badge's
                    // VoiceOver name as it was (M7 D).
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: .capsule)
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .accent: .accentColor
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

// MARK: - language direction

/// 「EN → JA」: the direction of a translation, short enough for a list row and
/// a detail header (M7 5, 6). `source == nil` shows 「自動」 for the source.
struct DesignLanguageDirection: View {
    var source: String?
    var target: String

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Text(LanguageCatalog.shortCode(for: source))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(LanguageCatalog.shortCode(for: target))
                .foregroundStyle(.primary)
        }
        .font(.system(size: Design.Font.caption, weight: .semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(LanguageCatalog.name(for: source)) から \(LanguageCatalog.name(for: target))"
        )
    }
}

// MARK: - relative time

// `RelativeTime` lives in `YakuCore` (`RelativeTime.swift`), where it is
// covered by tests, because the week boundary is logic rather than a colour.

