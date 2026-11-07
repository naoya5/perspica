import Foundation
import SwiftData
import YakuCore

/// One glossary entry (SPEC 11). The translation of `source` is forced to
/// `target` whenever `enabled` is true and the source text contains it.
@Model
final class GlossaryEntry {
    var source: String
    var target: String
    var enabled: Bool
    /// The order the table shows; the prompt keeps this order too.
    var sortOrder: Int

    init(source: String, target: String, enabled: Bool = true, sortOrder: Int = 0) {
        self.source = source
        self.target = target
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    var pair: GlossaryPair { GlossaryPair(source: source, target: target) }
}

extension GlossaryEntry {
    /// The samples the glossary starts with, disabled (SPEC 4.4:
    /// 「固有名詞を訳さない」見本).
    static func samples() -> [GlossaryEntry] {
        [
            ("Transformer", "Transformer"),
            ("Attention", "アテンション"),
            ("self-attention", "自己アテンション"),
            ("encoder", "エンコーダ"),
            ("decoder", "デコーダ"),
            ("BLEU", "BLEU"),
        ].enumerated().map { index, item in
            GlossaryEntry(source: item.0, target: item.1, enabled: false, sortOrder: index)
        }
    }
}
