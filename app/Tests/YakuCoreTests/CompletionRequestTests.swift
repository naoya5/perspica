import Foundation
import Testing
@testable import YakuCore

@Suite("CompletionRequest")
struct CompletionRequestTests {
    @Test("token estimate counts ASCII in fours and everything else singly")
    func estimate() {
        #expect(TokenEstimator.estimate("") == 0)
        #expect(TokenEstimator.estimate("abcd") == 1)
        #expect(TokenEstimator.estimate("abcde") == 1)
        #expect(TokenEstimator.estimate("あいうえお") == 5)
        #expect(TokenEstimator.estimate("abあ") == 1)
    }

    @Test("max_tokens is twice the estimate, clamped to 256...2048")
    func maxTokens() {
        #expect(CompletionRequest.maxTokens(forSource: "hi") == 256)
        #expect(CompletionRequest.maxTokens(forSource: String(repeating: "あ", count: 300)) == 600)
        #expect(CompletionRequest.maxTokens(forSource: String(repeating: "a", count: 100_000)) == 2048)
    }

    @Test("the JSON body matches SPEC 7.2")
    func body() throws {
        let request = CompletionRequest(prompt: "P", source: "hello world")
        let data = try request.body(model: "plamo-3-translate")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == "plamo-3-translate")
        #expect(object["prompt"] as? String == "P")
        #expect(object["temperature"] as? Double == 0)
        #expect(object["max_tokens"] as? Int == 256)
        #expect(object["stream"] as? Bool == true)
        #expect(object["cache_prompt"] as? Bool == true)
        #expect(object["stop"] as? [String] == ["<|plamo:tag|>", "<|plamo:bos|>"])
    }

    @Test("init(prompt:source:) derives max_tokens from the source text")
    func convenienceInit() {
        let request = CompletionRequest(prompt: "P", source: String(repeating: "あ", count: 500))
        #expect(request.maxTokens == 1000)
    }
}
