import AppKit

/// Text measurement shared by the panel's height calculation and its views.
///
/// The panel's window never resizes; only the glass shape inside it does, and
/// the shape's height has to be decided before the text is laid out. Measuring
/// with the same font and line spacing the view uses keeps the two in step.
enum TextMetrics {
    static func height(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        lineSpacing: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
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
