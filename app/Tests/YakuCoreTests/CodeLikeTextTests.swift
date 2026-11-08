import Foundation
import Testing

@testable import YakuCore

@Suite("Code-like text")
struct CodeLikeTextTests {
    // Lines read off a real documentation page (app.log, 2026-11-08).
    @Test("code lines are left alone", arguments: [
        "Llm=openai.LLM(",
        "model=os .getenv(\"OPENROUTER_MODEL\") , api_key=os.getenv(\"OPENROUTER_API_KEY\") ,",
        "base_url=\"https://openrouter.ai/api/v1\",",
        "),",
        "tts=inference. TTS(model=\"fishaudio/s2.1-pro\") ,",
        "LIVEKIT_API_SECRET.",
        "INSTRUCTIONS = \"••",
        "https://openrouter.ai/api/v1",
        "if (x > 0) { return y; }",
    ])
    func code(_ text: String) {
        #expect(CodeLikeText.isCodeLike(text))
    }

    @Test("prose and UI labels are translated", arguments: [
        "Why Speechmatics?",
        "Configure the speech-to-response pipeline",
        "LiveKit's AgentSession connects the three model providers.",
        "turn.",
        "Settings",
        "Play a sound",
        "Use the system alert sound",
        "The encoder maps an input sequence (x1, ..., xn) to a sequence of continuous representations.",
        "Never claim the real booking system was changed.",
        "エンコーダは 6 層からなる",
    ])
    func prose(_ text: String) {
        #expect(!CodeLikeText.isCodeLike(text))
    }

    @Test("a translation that only repeats the source is noticed")
    func unchanged() {
        #expect(CodeLikeText.isUnchanged(source: "LiveKit", translation: "LiveKit"))
        #expect(CodeLikeText.isUnchanged(source: "Llm=openai.LLM(", translation: "Llm = openai.LLM("))
        #expect(CodeLikeText.isUnchanged(source: "),", translation: "）、"))
        #expect(!CodeLikeText.isUnchanged(source: "Settings", translation: "設定"))
    }
}
