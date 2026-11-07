import Foundation

/// Removes the special tokens the model can leave at the end of a translation.
public enum TranslationCleanup {
    public static let trailingTokens = ["<|plamo:tag|>", "<|plamo:bos|>"]

    /// Strips trailing `<|plamo:tag|>` / `<|plamo:bos|>` tokens (and the
    /// whitespace they were sitting behind) until the text is stable.
    public static func clean(_ text: String) -> String {
        var result = text
        while true {
            let before = result
            for token in trailingTokens where result.hasSuffix(token) {
                result.removeLast(token.count)
            }
            while let last = result.last, last.isWhitespace {
                result.removeLast()
            }
            if result == before { break }
        }
        return result
    }
}
