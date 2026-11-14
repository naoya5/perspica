import Foundation

/// Inline formulas travel through the model as `{v0}`, `{v1}`, ... tokens.
/// PLaMo keeps such tokens in place (checked with the 0.8B model), so the
/// original formula glyphs can be placed back where the translation puts them.
public enum PDFFormulaPlaceholders {
    public enum Piece: Sendable, Equatable {
        case text(String)
        /// Index into the paragraph's formula segments, in source order.
        case formula(Int)
    }

    /// The text sent to the model, and the formula segments in token order.
    public static func source(for segments: [PDFTextSegment]) -> (text: String, formulas: [PDFTextSegment]) {
        var text = ""
        var formulas: [PDFTextSegment] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                text += value
            case .formula:
                text += "{v\(formulas.count)}"
                formulas.append(segment)
            }
        }
        return (text, formulas)
    }

    /// Splits a translation back into text and formulas. Returns nil unless
    /// every token from 0 to `formulaCount - 1` appears exactly once, because a
    /// lost or doubled formula would silently change the meaning.
    public static func pieces(from translation: String, formulaCount: Int) -> [Piece]? {
        var pieces: [Piece] = []
        var seen = Set<Int>()
        var rest = Substring(translation)
        while let match = rest.firstMatch(of: /\{v(\d{1,3})\}/) {
            guard let index = Int(match.output.1), index < formulaCount, seen.insert(index).inserted else {
                return nil
            }
            let before = rest[..<match.range.lowerBound]
            if !before.isEmpty { pieces.append(.text(String(before))) }
            pieces.append(.formula(index))
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        return seen.count == formulaCount ? pieces : nil
    }

    /// The source with each formula written as its Unicode text, for the
    /// fallback request when the model dropped or repeated a token.
    public static func plainSource(for segments: [PDFTextSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let value): value
            case .formula(let text, _, _): text
            }
        }.joined()
    }
}
