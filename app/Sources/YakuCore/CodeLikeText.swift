import Foundation

/// Tells source code, identifiers and stray symbols apart from prose, so the
/// screen overlay leaves them as they are (SPEC 9 の訳).
///
/// Measured on a documentation page: code lines such as
/// `model=os.getenv("OPENROUTER_MODEL"),` were read as Dutch, sent through the
/// model and came back as the same code in a different font, which looked like
/// broken English over the original.
public enum CodeLikeText {
    /// Share of code symbols among the non-space characters above which a line
    /// is treated as code even without a call or an assignment.
    public static let symbolRatio = 0.25
    /// The lower share that is enough when the text also contains a call.
    public static let callSymbolRatio = 0.1

    private static let codeSymbols: Set<Character> = [
        "=", "(", ")", "{", "}", "[", "]", ";", "<", ">", "\"", "`", "_", "\\", "|",
        "#", "$", "@", "*", "&", "^", "~",
    ]

    private static let assignment = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][\w.\[\]]*\s*[:+\-*/]?=\s*\S"#
    )
    private static let call = try! NSRegularExpression(pattern: #"[A-Za-z_][\w.]*\("#)
    private static let identifierToken = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9_.\-/:]+$"#
    )

    public static func isCodeLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Nothing to translate: brackets, commas and numbers only.
        guard trimmed.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return true }
        // Prose in Japanese or Chinese is never treated as code.
        if trimmed.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) { return false }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if assignment.firstMatch(in: trimmed, range: range) != nil { return true }

        let visible = trimmed.filter { !$0.isWhitespace }
        let symbols = visible.filter { codeSymbols.contains($0) }.count
        let ratio = Double(symbols) / Double(max(visible.count, 1))
        if call.firstMatch(in: trimmed, range: range) != nil, ratio >= callSymbolRatio { return true }

        if !trimmed.contains(where: \.isWhitespace),
           identifierToken.firstMatch(in: trimmed, range: range) != nil,
           trimmed.contains("_") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        return ratio >= symbolRatio
    }

    /// True when a translation only repeats the source (spacing and full-width
    /// punctuation aside), so drawing it would change nothing but the font.
    public static func isUnchanged(source: String, translation: String) -> Bool {
        normalized(source) == normalized(translation)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(folded.filter { !$0.isWhitespace && !"、。､｡,.".contains($0) }).lowercased()
    }
}
