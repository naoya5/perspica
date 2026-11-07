import Foundation
import NaturalLanguage

/// Source-language detection and the default target language (SPEC 5.1).
public enum LanguageDetector {
    public struct Detection: Sendable, Equatable {
        /// A PLaMo language code, or nil when nothing supported was recognised.
        public let code: String?
        /// The recogniser's confidence for `code`, 0...1.
        public let confidence: Double

        public init(code: String?, confidence: Double) {
            self.code = code
            self.confidence = confidence
        }
    }

    /// Below this many characters a low-confidence guess is not trusted.
    public static let shortTextLength = 20
    /// Confidence under which a short text keeps the previous language.
    public static let lowConfidence = 0.5

    public static func detect(_ text: String) -> Detection {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let best = hypotheses.max { $0.value < $1.value }
        guard let best else { return Detection(code: nil, confidence: 0) }
        return Detection(
            code: LanguageCatalog.normalizedCode(best.key.rawValue),
            confidence: best.value
        )
    }

    /// Applies SPEC 5.1's rule: a short text with a weak guess keeps the
    /// language used last time, unless the letters themselves rule it out.
    /// Without that check, "hello" typed after a Japanese sentence was sent
    /// as Japanese and came back untranslated. `detect` is injectable so the
    /// rule can be tested without depending on the recogniser's numbers.
    public static func resolve(
        text: String,
        previous: String?,
        detect: (String) -> Detection = LanguageDetector.detect
    ) -> String? {
        let detection = detect(text)
        guard text.count < shortTextLength, detection.confidence < lowConfidence else {
            return detection.code
        }
        switch WritingScript.of(text) {
        case .kana:
            return "ja"
        case .han:
            if let previous, hanCodes.contains(previous) { return previous }
            if let code = detection.code, hanCodes.contains(code) { return code }
            return "ja"
        case .latin:
            if let previous, !nonLatinCodes.contains(previous) { return previous }
            if let code = detection.code, !nonLatinCodes.contains(code) { return code }
            return "en"
        case .other, .none:
            return previous ?? detection.code
        }
    }

    private static let hanCodes: Set<String> = ["ja", "zh-hans", "zh-hant"]

    /// Supported languages that are not normally written in Latin letters.
    private static let nonLatinCodes: Set<String> = [
        "ja", "zh-hans", "zh-hant", "ko", "ar", "be", "bg", "bn", "el", "fa", "gu",
        "he", "hi", "hy", "ka", "kk", "km", "ml", "mn", "mr", "my", "ne", "pa", "ru",
        "si", "sr", "ta", "te", "th", "uk", "ur", "yi",
    ]

    /// The kind of letters a text is written in, which is enough to overrule a
    /// weak guess for short text.
    enum WritingScript: Equatable {
        case kana, han, latin, other, none

        static func of(_ text: String) -> WritingScript {
            var hasHan = false
            var hasLatin = false
            var hasOther = false
            for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
                    return .kana
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
                    hasHan = true
                case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                    hasLatin = true
                default:
                    hasOther = true
                }
            }
            if hasHan { return .han }
            if hasOther { return .other }
            return hasLatin ? .latin : .none
        }
    }
    /// Japanese goes to English, everything else goes to Japanese.
    public static func defaultTarget(forSource source: String?) -> String {
        source == "ja" ? "en" : "ja"
    }
}
