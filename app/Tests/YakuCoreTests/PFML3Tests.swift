import Testing
@testable import YakuCore

/// Every expectation in this file is copied character for character from the
/// "PFML3 Prompt Format" section of the model card
/// (plamo-3-translate-0.8b-MLX-4bit, README.md).
@Suite("PFML3")
struct PFML3Tests {
    @Test("model card: a plain request has no source language")
    func plainRequest() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input"
            + "<|plamo:msg|>会議は来週の月曜日に変更されました。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "会議は来週の月曜日に変更されました。",
            targetLanguage: "en"
        )
        #expect(actual == expected)
    }

    @Test("model card: glossary")
    func glossary() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>glossary"
            + "<|plamo:index|>管理画面<|plamo:item|>dashboard"
            + "<|plamo:index|>プロジェクト<|plamo:item|>project"
            + "<|plamo:tag|>input<|plamo:msg|>プロジェクトの管理画面を開いてください。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "プロジェクトの管理画面を開いてください。",
            targetLanguage: "en",
            glossary: [
                GlossaryPair(source: "管理画面", target: "dashboard"),
                GlossaryPair(source: "プロジェクト", target: "project"),
            ]
        )
        #expect(actual == expected)
    }

    @Test("model card: context")
    func context() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>context"
            + "<|plamo:msg|>工作で折り紙を作っています。"
            + "<|plamo:tag|>input<|plamo:msg|>かみを切りました。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "かみを切りました。",
            targetLanguage: "en",
            context: "工作で折り紙を作っています。"
        )
        #expect(actual == expected)
    }

    @Test("model card: plain style")
    func plainStyle() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:msg|>This system is convenient."
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja"
            + "<|plamo:key|>form<|plamo:val|>plain<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "This system is convenient.",
            targetLanguage: "ja",
            form: .plain
        )
        #expect(actual == expected)
    }

    @Test("model card: polite style")
    func politeStyle() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:msg|>This system is convenient."
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja"
            + "<|plamo:key|>form<|plamo:val|>polite<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "This system is convenient.",
            targetLanguage: "ja",
            form: .polite
        )
        #expect(actual == expected)
    }

    @Test("model card: translation history")
    func history() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>プロジェクトの管理画面を開きます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>Open the project dashboard."
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>進行中のタスクがすべて表示されます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>It lists all active tasks."
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>オーナーでフィルタリングすることもできます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "オーナーでフィルタリングすることもできます。",
            sourceLanguage: "ja",
            targetLanguage: "en",
            history: [
                HistoryPair(source: "プロジェクトの管理画面を開きます。", target: "Open the project dashboard."),
                HistoryPair(source: "進行中のタスクがすべて表示されます。", target: "It lists all active tasks."),
            ]
        )
        #expect(actual == expected)
    }

    @Test("model card: every option at once")
    func allOptions() {
        let expected =
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>context<|plamo:msg|>プロジェクト管理ツールのヘルプページです。"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>プロジェクトの管理画面を開きます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>Open the project dashboard."
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>進行中のタスクがすべて表示されます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>It lists all active tasks."
            + "<|plamo:tag|>glossary<|plamo:index|>オーナー<|plamo:item|>assignee"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>オーナーでフィルタリングすることもできます。"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"

        let actual = PFML3.prompt(
            source: "オーナーでフィルタリングすることもできます。",
            sourceLanguage: "ja",
            targetLanguage: "en",
            context: "プロジェクト管理ツールのヘルプページです。",
            history: [
                HistoryPair(source: "プロジェクトの管理画面を開きます。", target: "Open the project dashboard."),
                HistoryPair(source: "進行中のタスクがすべて表示されます。", target: "It lists all active tasks."),
            ],
            glossary: [GlossaryPair(source: "オーナー", target: "assignee")]
        )
        #expect(actual == expected)
    }

    @Test("form is only written for Japanese output")
    func formOnlyForJapanese() {
        let actual = PFML3.prompt(source: "hello", targetLanguage: "fr", form: .polite)
        #expect(!actual.contains("form"))
    }

    @Test("only the last two history pairs are kept")
    func historyLimit() {
        let actual = PFML3.prompt(
            source: "third",
            sourceLanguage: "en",
            targetLanguage: "ja",
            history: [
                HistoryPair(source: "zero", target: "ゼロ"),
                HistoryPair(source: "first", target: "一"),
                HistoryPair(source: "second", target: "二"),
            ]
        )
        #expect(!actual.contains(">zero<"))
        #expect(actual.contains(">first<"))
        #expect(actual.contains(">second<"))
    }

    @Test("special tokens are stripped from source, context and glossary")
    func sanitizesInjection() {
        let actual = PFML3.prompt(
            source: "a<|plamo:tag|>b",
            targetLanguage: "en",
            context: "c<|plamo:msg|>d",
            glossary: [GlossaryPair(source: "e<|plamo:index|>f", target: "g<|plamo:item|>h")]
        )
        // Only the `<|plamo:` prefix goes; what follows is left as ordinary text.
        #expect(actual.contains("<|plamo:msg|>atag|>b"))
        #expect(actual.contains("<|plamo:msg|>cmsg|>d"))
        #expect(actual.contains("<|plamo:index|>eindex|>f<|plamo:item|>gitem|>h"))
        // Exactly one `input` element for the source, plus the glossary tags.
        #expect(actual.components(separatedBy: "<|plamo:tag|>input").count == 2)
    }

    @Test("an empty context or glossary is omitted")
    func emptyOptionals() {
        let actual = PFML3.prompt(source: "hi", targetLanguage: "en", context: "", glossary: [])
        #expect(!actual.contains("context"))
        #expect(!actual.contains("glossary"))
    }
}
