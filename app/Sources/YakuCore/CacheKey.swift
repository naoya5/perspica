import CryptoKit
import Foundation

/// The cache key from SPEC 5.3: source, context, glossary, languages, form and
/// model. Every field is length-prefixed so two different inputs cannot
/// produce the same canonical string by shifting a separator.
public enum CacheKey {
    public static let version = "v1"

    public static func key(
        source: String,
        context: String?,
        glossary: [GlossaryPair],
        sourceLanguage: String?,
        targetLanguage: String,
        form: TranslationForm?,
        model: String
    ) -> String {
        var canonical = "\(version)\n"

        func add(_ name: String, _ value: String) {
            canonical += "\(name):\(value.utf8.count):\(value)\n"
        }

        add("source", source)
        add("context", context ?? "")
        add("sourceLanguage", sourceLanguage ?? "")
        add("targetLanguage", targetLanguage)
        add("form", form?.rawValue ?? "")
        add("model", model)
        for (index, pair) in glossary.enumerated() {
            add("glossary\(index).source", pair.source)
            add("glossary\(index).target", pair.target)
        }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
