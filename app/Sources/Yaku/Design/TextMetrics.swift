import AppKit
import YakuCore

/// Text measurement shared by the panel's height calculation and its views.
///
/// The panel's window never resizes; only the glass shape inside it does, and
/// the shape's height has to be decided before the text is laid out. Measuring
/// with the same font and line spacing the view uses keeps the two in step.
///
/// The panel asks for the source text's height on every redraw, and the reveal
/// animation redraws at 30Hz, so the same string is measured dozens of times a
/// second. `boundingRect` breaks the whole string into lines each time; M5's
/// profile showed it as CoreText shaping on the main thread, and keeping the
/// answers took the translating CPU from 18.5% to 12.3% (M5.md 4.2).
enum TextMetrics {
    private struct Key: Hashable {
        let text: String
        let width: CGFloat
        let size: CGFloat
        let lineSpacing: CGFloat
        let weight: CGFloat
    }

    private static let answers = Memo<Key, CGFloat>(limit: 16)

    static func height(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        lineSpacing: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = Key(
            text: text,
            width: width,
            size: size,
            lineSpacing: lineSpacing,
            weight: weight.rawValue
        )
        return answers.value(for: key) {
            measure(text, width: width, size: size, lineSpacing: lineSpacing, weight: weight)
        }
    }

    private static func measure(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        lineSpacing: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .paragraphStyle: style,
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }

    static func lineHeight(size: CGFloat, lineSpacing: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        height("Ag", width: 10_000, size: size, lineSpacing: lineSpacing, weight: weight)
    }
}
