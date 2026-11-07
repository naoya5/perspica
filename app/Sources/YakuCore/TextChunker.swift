import Foundation
import NaturalLanguage

/// One piece of a long source text (SPEC 7.4).
public struct TextChunk: Sendable, Equatable {
    public let text: String
    /// True for the first chunk of a paragraph; the join puts a blank line
    /// before it.
    public let startsParagraph: Bool
    public let index: Int
    public let total: Int

    public init(text: String, startsParagraph: Bool, index: Int, total: Int) {
        self.text = text
        self.startsParagraph = startsParagraph
        self.index = index
        self.total = total
    }
}

/// Splits a long source text so that one request stays inside the engine's
/// window (SPEC 7.4).
///
/// The limit is expressed as a weighted length: CJK characters count double,
/// so "1,200 characters, or 600 for Japanese" becomes a single threshold of
/// 1,200. A request's input, context, glossary and output together must stay
/// under 4,096 tokens (`-c 16384 --parallel 4`), which this keeps comfortably.
public enum TextChunker {
    public static let weightedLimit = 1200

    public static func weightedLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + weight($1) }
    }

    public static func needsSplitting(_ text: String) -> Bool {
        weightedLength(text) > weightedLimit
    }

    public static func chunks(from text: String) -> [TextChunk] {
        let normalized = normalize(text)

        guard needsSplitting(normalized) else {
            let single = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !single.isEmpty else { return [] }
            return [TextChunk(text: single, startsParagraph: true, index: 0, total: 1)]
        }

        var pieces: [(text: String, startsParagraph: Bool)] = []
        for paragraph in paragraphs(in: normalized) {
            if weightedLength(paragraph) <= weightedLimit {
                pieces.append((paragraph, true))
            } else {
                var first = true
                for group in sentenceGroups(in: paragraph) {
                    pieces.append((group, first))
                    first = false
                }
            }
        }

        let total = pieces.count
        return pieces.enumerated().map { offset, piece in
            TextChunk(
                text: piece.text,
                startsParagraph: piece.startsParagraph,
                index: offset,
                total: total
            )
        }
    }

    /// Reassembles translated chunks: chunks of the same paragraph follow each
    /// other directly, paragraphs are separated by a blank line.
    public static func join(_ translations: [String], chunks: [TextChunk]) -> String {
        var out = ""
        for (index, translation) in translations.enumerated() {
            if index > 0, index < chunks.count, chunks[index].startsParagraph {
                out += "\n\n"
            }
            out += translation
        }
        return out
    }

    // MARK: internals

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func weight(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK punctuation
             0x3040...0x309F,   // hiragana
             0x30A0...0x30FF,   // katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xAC00...0xD7AF,   // hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2FA1F: // CJK extensions B and beyond
            return 2
        default:
            return 1
        }
    }

    /// Paragraphs are separated by a blank line. The original line breaks
    /// inside a paragraph are kept.
    private static func paragraphs(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Groups whole sentences up to the limit.
    ///
    /// A sentence's slice runs from its own start to the next sentence's start,
    /// so the whitespace that separates them belongs to the earlier slice. A
    /// group is then a plain substring of the paragraph, which keeps the text
    /// byte-for-byte intact. A single sentence over the limit is cut at the
    /// limit instead.
    private static func sentenceGroups(in paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph

        var starts: [String.Index] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            starts.append(range.lowerBound)
            return true
        }
        guard !starts.isEmpty else { return hardSplit(paragraph) }

        var sentences: [Range<String.Index>] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : paragraph.endIndex
            guard start < end else { continue }
            if paragraph[start..<end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            sentences.append(start..<end)
        }
        guard !sentences.isEmpty else {
            return hardSplit(paragraph[...])
                .map { trim(String(paragraph[$0])) }
                .filter { !$0.isEmpty }
        }

        var groups: [Range<String.Index>] = []
        for sentence in sentences {
            if weightedLength(String(paragraph[sentence])) > weightedLimit {
                groups.append(contentsOf: hardSplit(paragraph[sentence]))
                continue
            }
            if let last = groups.last {
                let candidate = paragraph[last.lowerBound..<sentence.upperBound]
                if weightedLength(String(candidate)) <= weightedLimit {
                    groups[groups.count - 1] = last.lowerBound..<sentence.upperBound
                    continue
                }
            }
            groups.append(sentence)
        }

        // Groups are contiguous slices of the paragraph, so no whitespace is
        // lost between them; the paragraph's own ends were trimmed earlier.
        return groups
            .map { String(paragraph[$0]) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Last resort: cut at the weighted limit. The ranges keep the original
    /// indices, so the caller can place the pieces back into the paragraph.
    private static func hardSplit(_ text: Substring) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var start = text.startIndex
        var currentWeight = 0
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let characterWeight = character.unicodeScalars.reduce(0) { $0 + weight($1) }
            if currentWeight + characterWeight > weightedLimit, start < index {
                pieces.append(start..<index)
                start = index
                currentWeight = 0
            }
            currentWeight += characterWeight
            index = text.index(after: index)
        }
        if start < text.endIndex { pieces.append(start..<text.endIndex) }
        return pieces
    }

    private static func hardSplit(_ text: String) -> [String] {
        hardSplit(text[...])
            .map { trim(String(text[$0])) }
            .filter { !$0.isEmpty }
    }

    private static func trim(_ piece: String) -> String {
        piece.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
