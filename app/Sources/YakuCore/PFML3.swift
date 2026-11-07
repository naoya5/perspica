import Foundation

/// One glossary entry: the source term and the translation that must be used.
public struct GlossaryPair: Sendable, Equatable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// One already translated source/translation pair, used as translation history.
public struct HistoryPair: Sendable, Equatable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// Japanese output style. Only meaningful when the target language is `ja`.
public enum TranslationForm: String, Sendable, CaseIterable {
    case plain
    case polite
}

/// Builds PLaMo's PFML3 prompt by hand (SPEC 7.2).
///
/// The layout follows the model card exactly:
/// `dataset` → [`context`] → history `input`/`output` pairs →
/// [`glossary`] → current `input` → `output`.
public enum PFML3 {
    /// `<|plamo:bos|>` is deliberately absent: the server adds it.
    public static let dataset = "<|plamo:tag|>dataset<|plamo:msg|>translation"

    /// The maximum number of history pairs the prompt will carry.
    public static let historyLimit = 2

    /// Strips any `<|plamo:` prefix so source text can never inject a special token.
    public static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<|plamo:", with: "")
    }

    public static func prompt(
        source: String,
        sourceLanguage: String? = nil,
        targetLanguage: String,
        form: TranslationForm? = nil,
        context: String? = nil,
        history: [HistoryPair] = [],
        glossary: [GlossaryPair] = []
    ) -> String {
        var out = dataset

        if let context, !context.isEmpty {
            out += "<|plamo:tag|>context<|plamo:msg|>" + sanitize(context)
        }

        for pair in history.suffix(historyLimit) {
            out += inputElement(language: sourceLanguage, body: pair.source)
            out += outputElement(language: targetLanguage, form: nil, body: pair.target)
        }

        if !glossary.isEmpty {
            out += "<|plamo:tag|>glossary"
            for pair in glossary {
                out += "<|plamo:index|>" + sanitize(pair.source)
                out += "<|plamo:item|>" + sanitize(pair.target)
            }
        }

        out += inputElement(language: sourceLanguage, body: source)
        out += outputElement(language: targetLanguage, form: form, body: "")
        return out
    }

    private static func inputElement(language: String?, body: String) -> String {
        var element = "<|plamo:tag|>input"
        if let language, !language.isEmpty {
            element += "<|plamo:key|>lang<|plamo:val|>" + language
        }
        element += "<|plamo:msg|>" + sanitize(body)
        return element
    }

    private static func outputElement(language: String, form: TranslationForm?, body: String) -> String {
        var element = "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + language
        // `form` only applies to Japanese output (model card: only with target_lang="ja").
        if let form, language == "ja" {
            element += "<|plamo:key|>form<|plamo:val|>" + form.rawValue
        }
        element += "<|plamo:msg|>" + sanitize(body)
        return element
    }
}
