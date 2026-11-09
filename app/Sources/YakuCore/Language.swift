import Foundation

/// One of the 53 languages PLaMo 3 Translate supports (model card, SPEC 5.1).
///
/// The `code` is the value that goes into PFML3's `lang` attribute. The model
/// card lists Simplified and Traditional Chinese as separate codes
/// (`zh-hans` / `zh-hant`), which is why the catalogue has 53 entries while
/// Hugging Face shows 52.
public struct Language: Sendable, Hashable, Identifiable {
    public let code: String
    /// Name shown in the app. The interface is Japanese, so the menu is too.
    public let japaneseName: String
    public let englishName: String

    public var id: String { code }

    public init(code: String, japaneseName: String, englishName: String) {
        self.code = code
        self.japaneseName = japaneseName
        self.englishName = englishName
    }
}

/// The language list, its menu order and the identifier normalisation that
/// turns `NLLanguageRecognizer`'s output into a PLaMo language code.
public enum LanguageCatalog {
    public static let all: [Language] = [
        Language(code: "ja", japaneseName: "日本語", englishName: "Japanese"),
        Language(code: "en", japaneseName: "英語", englishName: "English"),
        Language(code: "zh-hans", japaneseName: "中国語（簡体）", englishName: "Chinese (Simplified)"),
        Language(code: "zh-hant", japaneseName: "中国語（繁体）", englishName: "Chinese (Traditional)"),
        Language(code: "ko", japaneseName: "韓国語", englishName: "Korean"),
        Language(code: "ar", japaneseName: "アラビア語", englishName: "Arabic"),
        Language(code: "az", japaneseName: "アゼルバイジャン語", englishName: "Azerbaijani"),
        Language(code: "be", japaneseName: "ベラルーシ語", englishName: "Belarusian"),
        Language(code: "bg", japaneseName: "ブルガリア語", englishName: "Bulgarian"),
        Language(code: "bn", japaneseName: "ベンガル語", englishName: "Bengali"),
        Language(code: "ca", japaneseName: "カタルーニャ語", englishName: "Catalan"),
        Language(code: "ceb", japaneseName: "セブアノ語", englishName: "Cebuano"),
        Language(code: "de", japaneseName: "ドイツ語", englishName: "German"),
        Language(code: "es", japaneseName: "スペイン語", englishName: "Spanish"),
        Language(code: "et", japaneseName: "エストニア語", englishName: "Estonian"),
        Language(code: "eu", japaneseName: "バスク語", englishName: "Basque"),
        Language(code: "fa", japaneseName: "ペルシア語", englishName: "Persian"),
        Language(code: "fr", japaneseName: "フランス語", englishName: "French"),
        Language(code: "gu", japaneseName: "グジャラート語", englishName: "Gujarati"),
        Language(code: "he", japaneseName: "ヘブライ語", englishName: "Hebrew"),
        Language(code: "hi", japaneseName: "ヒンディー語", englishName: "Hindi"),
        Language(code: "hr", japaneseName: "クロアチア語", englishName: "Croatian"),
        Language(code: "hu", japaneseName: "ハンガリー語", englishName: "Hungarian"),
        Language(code: "hy", japaneseName: "アルメニア語", englishName: "Armenian"),
        Language(code: "id", japaneseName: "インドネシア語", englishName: "Indonesian"),
        Language(code: "it", japaneseName: "イタリア語", englishName: "Italian"),
        Language(code: "jv", japaneseName: "ジャワ語", englishName: "Javanese"),
        Language(code: "ka", japaneseName: "ジョージア語", englishName: "Georgian"),
        Language(code: "kk", japaneseName: "カザフ語", englishName: "Kazakh"),
        Language(code: "km", japaneseName: "クメール語", englishName: "Khmer"),
        Language(code: "lt", japaneseName: "リトアニア語", englishName: "Lithuanian"),
        Language(code: "lv", japaneseName: "ラトビア語", englishName: "Latvian"),
        Language(code: "ml", japaneseName: "マラヤーラム語", englishName: "Malayalam"),
        Language(code: "mr", japaneseName: "マラーティー語", englishName: "Marathi"),
        Language(code: "ms", japaneseName: "マレー語", englishName: "Malay"),
        Language(code: "my", japaneseName: "ビルマ語", englishName: "Burmese"),
        Language(code: "ne", japaneseName: "ネパール語", englishName: "Nepali"),
        Language(code: "nl", japaneseName: "オランダ語", englishName: "Dutch"),
        Language(code: "pa", japaneseName: "パンジャブ語", englishName: "Punjabi"),
        Language(code: "pl", japaneseName: "ポーランド語", englishName: "Polish"),
        Language(code: "ru", japaneseName: "ロシア語", englishName: "Russian"),
        Language(code: "si", japaneseName: "シンハラ語", englishName: "Sinhala"),
        Language(code: "sk", japaneseName: "スロバキア語", englishName: "Slovak"),
        Language(code: "sl", japaneseName: "スロベニア語", englishName: "Slovenian"),
        Language(code: "sr", japaneseName: "セルビア語", englishName: "Serbian"),
        Language(code: "sw", japaneseName: "スワヒリ語", englishName: "Swahili"),
        Language(code: "ta", japaneseName: "タミル語", englishName: "Tamil"),
        Language(code: "te", japaneseName: "テルグ語", englishName: "Telugu"),
        Language(code: "th", japaneseName: "タイ語", englishName: "Thai"),
        Language(code: "tl", japaneseName: "タガログ語", englishName: "Tagalog"),
        Language(code: "ur", japaneseName: "ウルドゥー語", englishName: "Urdu"),
        Language(code: "uz", japaneseName: "ウズベク語", englishName: "Uzbek"),
        Language(code: "vi", japaneseName: "ベトナム語", englishName: "Vietnamese"),
    ]

    /// Shown above the rest in the language menu, in this order (SPEC 4.2).
    public static let frequentCodes = ["ja", "en", "zh-hans", "zh-hant", "ko", "de", "fr", "es"]

    /// Used for the source-language slot when the language could not be detected.
    public static let automaticName = "自動"

    private static let byCode: [String: Language] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
    }()

    public static func language(for code: String?) -> Language? {
        guard let code else { return nil }
        return byCode[code]
    }

    /// Japanese display name, or the code itself when it is not one of the 53.
    public static func name(for code: String?) -> String {
        guard let code, !code.isEmpty else { return automaticName }
        return byCode[code]?.japaneseName ?? code
    }

    /// The two-letter code a row or a badge shows for a language:
    /// `en` → `EN`, `zh-hans` → `ZH`. `nil` (or empty) is 「自動」, the same word
    /// the source slot uses.
    public static func shortCode(for code: String?) -> String {
        guard let code, !code.isEmpty else { return automaticName }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return base.uppercased()
    }

    public static let frequent: [Language] = frequentCodes.compactMap { byCode[$0] }

    /// Everything not in `frequent`, ordered by Japanese name. Built once: the
    /// panel's language menu reads it on every redraw, and sorting 45 names
    /// with `localizedStandardCompare` each time was 2% of the main thread
    /// while translating (perf review 2026-11-09).
    public static let others: [Language] = {
        let frequentSet = Set(frequentCodes)
        return all
            .filter { !frequentSet.contains($0.code) }
            .sorted { $0.japaneseName.localizedStandardCompare($1.japaneseName) == .orderedAscending }
    }()

    /// Maps a BCP-47 identifier from `NLLanguageRecognizer` onto a PLaMo code.
    /// Returns nil for languages the model does not support.
    public static func normalizedCode(_ identifier: String) -> String? {
        let lower = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = lower.split(separator: "-").first.map(String.init) ?? lower

        // Legacy and alternate tags the recogniser can still emit.
        let aliases: [String: String] = [
            "iw": "he",
            "in": "id",
            "ji": "yi",
            "fil": "tl",
            "cmn": "zh-hans",
            "zh-cn": "zh-hans",
            "zh-sg": "zh-hans",
            "zh-tw": "zh-hant",
            "zh-hk": "zh-hant",
            "zh-mo": "zh-hant",
            "nb": "no",
        ]
        if let alias = aliases[lower] { return byCode[alias] != nil ? alias : nil }
        if let alias = aliases[base] { return byCode[alias] != nil ? alias : nil }

        if lower == "zh" { return "zh-hans" }
        if byCode[lower] != nil { return lower }
        if byCode[base] != nil { return base }
        return nil
    }
}
