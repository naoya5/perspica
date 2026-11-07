import Foundation
import Testing
@testable import YakuCore

@Suite("TranslationCleanup")
struct TranslationCleanupTests {
    @Test("removes a trailing tag token")
    func trailingTag() {
        #expect(TranslationCleanup.clean("こんにちは。<|plamo:tag|>") == "こんにちは。")
    }

    @Test("removes a trailing bos token")
    func trailingBos() {
        #expect(TranslationCleanup.clean("Hello.<|plamo:bos|>") == "Hello.")
    }

    @Test("removes several trailing tokens and the whitespace behind them")
    func severalTokens() {
        #expect(TranslationCleanup.clean("Hello.\n<|plamo:tag|><|plamo:bos|>\n") == "Hello.")
    }

    @Test("leaves the text alone when there is nothing to remove")
    func untouched() {
        #expect(TranslationCleanup.clean("そのまま。") == "そのまま。")
    }

    @Test("does not remove a token in the middle of the text")
    func keepsInnerTokens() {
        // `<|plamo:` in the middle is data, only trailing tokens are stripped.
        #expect(TranslationCleanup.clean("a<|plamo:tag|>b") == "a<|plamo:tag|>b")
    }

    @Test("empty input stays empty")
    func empty() {
        #expect(TranslationCleanup.clean("") == "")
        #expect(TranslationCleanup.clean("<|plamo:tag|>") == "")
    }
}
