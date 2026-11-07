import Foundation
import Testing
@testable import YakuCore

@Suite("Text chunking")
struct TextChunkerTests {
    @Test("short text stays one chunk")
    func shortText() {
        let chunks = TextChunker.chunks(from: "Attention is all you need.")
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Attention is all you need.")
        #expect(chunks[0].startsParagraph)
        #expect(chunks[0].index == 0)
        #expect(chunks[0].total == 1)
    }

    @Test("empty text produces no chunks")
    func empty() {
        #expect(TextChunker.chunks(from: "").isEmpty)
        #expect(TextChunker.chunks(from: "   \n\n  ").isEmpty)
    }

    @Test("weighted length counts CJK double")
    func weightedLength() {
        #expect(TextChunker.weightedLength("abcd") == 4)
        #expect(TextChunker.weightedLength("あいうえ") == 8)
        #expect(TextChunker.weightedLength("abあい") == 6)
    }

    @Test("1200 Latin characters do not split, 1201 do")
    func latinThreshold() {
        let under = String(repeating: "a", count: 1200)
        let over = String(repeating: "a", count: 1201)
        #expect(TextChunker.needsSplitting(under) == false)
        #expect(TextChunker.needsSplitting(over) == true)
    }

    @Test("600 Japanese characters do not split, 601 do")
    func japaneseThreshold() {
        let under = String(repeating: "あ", count: 600)
        let over = String(repeating: "あ", count: 601)
        #expect(TextChunker.needsSplitting(under) == false)
        #expect(TextChunker.needsSplitting(over) == true)
    }

    @Test("a long paragraph splits at sentence boundaries and keeps every word")
    func sentenceSplit() {
        let sentence = "The transformer replaces recurrence with attention. "
        let text = String(repeating: sentence, count: 30)
        let chunks = TextChunker.chunks(from: text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { TextChunker.weightedLength($0.text) <= TextChunker.weightedLimit })
        // The pieces put back together are the original text.
        let joined = chunks.map(\.text).joined()
        #expect(joined == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(chunks.allSatisfy { $0.total == chunks.count })
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
    }

    @Test("paragraphs are marked and separated on join")
    func paragraphs() {
        let paragraph = String(repeating: "attention ", count: 130)
        let text = paragraph + "\n\n" + paragraph
        let chunks = TextChunker.chunks(from: text)
        #expect(chunks.count > 2)
        #expect(chunks.first?.startsParagraph == true)
        let secondStart = chunks.firstIndex { $0.startsParagraph && $0.index > 0 }
        #expect(secondStart != nil)
        if let secondStart {
            // The paragraph marker is only on the first chunk of paragraph two.
            #expect(chunks[secondStart].startsParagraph)
            #expect(chunks[secondStart - 1].startsParagraph == false)
        }
    }

    @Test("a single over-long sentence is hard split inside the limit")
    func hardSplit() {
        let text = String(repeating: "a", count: 2500)
        let chunks = TextChunker.chunks(from: text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { TextChunker.weightedLength($0.text) <= TextChunker.weightedLimit })
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test("join inserts a blank line only before a new paragraph")
    func join() {
        let chunks = [
            TextChunk(text: "a", startsParagraph: true, index: 0, total: 3),
            TextChunk(text: "b", startsParagraph: false, index: 1, total: 3),
            TextChunk(text: "c", startsParagraph: true, index: 2, total: 3),
        ]
        #expect(TextChunker.join(["A", "B", "C"], chunks: chunks) == "AB\n\nC")
    }

    @Test("a partially received translation joins correctly")
    func joinPartial() {
        let chunks = [
            TextChunk(text: "a", startsParagraph: true, index: 0, total: 3),
            TextChunk(text: "b", startsParagraph: false, index: 1, total: 3),
            TextChunk(text: "c", startsParagraph: true, index: 2, total: 3),
        ]
        #expect(TextChunker.join(["A"], chunks: chunks) == "A")
        #expect(TextChunker.join(["A", "B"], chunks: chunks) == "AB")
    }
}
