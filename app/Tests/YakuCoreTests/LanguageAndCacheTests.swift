import Foundation
import Testing
@testable import YakuCore

@Suite("Glossary filtering")
struct GlossaryFilterTests {
    private let glossary = [
        GlossaryPair(source: "Attention", target: "アテンション"),
        GlossaryPair(source: "Transformer", target: "Transformer"),
        GlossaryPair(source: "encoder", target: "エンコーダー"),
    ]

    @Test("only terms that appear in the source are kept")
    func filters() {
        let result = GlossaryFilter.relevant(glossary, in: "Attention is all you need.")
        #expect(result.map(\.source) == ["Attention"])
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        let result = GlossaryFilter.relevant(glossary, in: "the ATTENTION mechanism and the transformer")
        #expect(result.map(\.source) == ["Attention", "Transformer"])
    }

    @Test("order follows the glossary, duplicates collapse")
    func orderAndDuplicates() {
        let doubled = glossary + [GlossaryPair(source: "attention", target: "注意")]
        let result = GlossaryFilter.relevant(doubled, in: "Attention, attention, attention.")
        #expect(result.map(\.target) == ["アテンション"])
    }

    @Test("empty sources are dropped")
    func emptySource() {
        let result = GlossaryFilter.relevant([GlossaryPair(source: "  ", target: "x")], in: "anything")
        #expect(result.isEmpty)
    }

    @Test("nothing matches an empty source text")
    func emptyText() {
        #expect(GlossaryFilter.relevant(glossary, in: "").isEmpty)
    }
}

@Suite("Cache key")
struct CacheKeyTests {
    private let base = (
        source: "Attention is all you need.",
        context: "paper",
        glossary: [GlossaryPair(source: "Attention", target: "アテンション")],
        sourceLanguage: "en" as String?,
        targetLanguage: "ja",
        form: TranslationForm.polite,
        model: "plamo-3-translate"
    )

    private func key(
        source: String? = nil,
        context: String?? = nil,
        glossary: [GlossaryPair]? = nil,
        sourceLanguage: String?? = nil,
        targetLanguage: String? = nil,
        form: TranslationForm?? = nil,
        model: String? = nil
    ) -> String {
        CacheKey.key(
            source: source ?? base.source,
            context: context ?? base.context,
            glossary: glossary ?? base.glossary,
            sourceLanguage: sourceLanguage ?? base.sourceLanguage,
            targetLanguage: targetLanguage ?? base.targetLanguage,
            form: form ?? base.form,
            model: model ?? base.model
        )
    }

    @Test("the same inputs give the same key")
    func stable() {
        #expect(key() == key())
        #expect(key().count == 64)
    }

    @Test("every field changes the key")
    func everyFieldMatters() {
        let original = key()
        #expect(key(source: "Something else.") != original)
        #expect(key(context: "other") != original)
        #expect(key(context: .some(nil)) != original)
        #expect(key(glossary: []) != original)
        #expect(key(glossary: [GlossaryPair(source: "Attention", target: "注意")]) != original)
        #expect(key(sourceLanguage: "ja") != original)
        #expect(key(sourceLanguage: .some(nil)) != original)
        #expect(key(targetLanguage: "en") != original)
        #expect(key(form: .plain) != original)
        #expect(key(form: .some(nil)) != original)
        #expect(key(model: "other-model") != original)
    }

    @Test("moving text between fields changes the key")
    func lengthPrefixPreventsCollision() {
        let a = CacheKey.key(source: "ab", context: "c", glossary: [], sourceLanguage: nil,
                             targetLanguage: "ja", form: nil, model: "m")
        let b = CacheKey.key(source: "a", context: "bc", glossary: [], sourceLanguage: nil,
                             targetLanguage: "ja", form: nil, model: "m")
        #expect(a != b)
    }

    @Test("glossary order matters")
    func glossaryOrder() {
        let one = CacheKey.key(source: "s", context: nil, glossary: [
            GlossaryPair(source: "a", target: "1"),
            GlossaryPair(source: "b", target: "2"),
        ], sourceLanguage: nil, targetLanguage: "ja", form: nil, model: "m")
        let two = CacheKey.key(source: "s", context: nil, glossary: [
            GlossaryPair(source: "b", target: "2"),
            GlossaryPair(source: "a", target: "1"),
        ], sourceLanguage: nil, targetLanguage: "ja", form: nil, model: "m")
        #expect(one != two)
    }
}
