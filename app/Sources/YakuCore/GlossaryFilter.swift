import Foundation

/// Narrows a glossary to the entries that actually appear in the source text
/// (SPEC 5.2): only those are sent to the model.
public enum GlossaryFilter {
    public static func relevant(_ glossary: [GlossaryPair], in text: String) -> [GlossaryPair] {
        let haystack = text.lowercased()
        var seen = Set<String>()
        var result: [GlossaryPair] = []

        for pair in glossary {
            let needle = pair.source
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !needle.isEmpty else { continue }
            guard !seen.contains(needle) else { continue }
            guard haystack.contains(needle) else { continue }
            seen.insert(needle)
            result.append(pair)
        }
        return result
    }
}
