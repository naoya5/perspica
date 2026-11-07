import Foundation
import Testing
@testable import YakuCore

@Suite("Language catalog")
struct LanguageCatalogTests {
    @Test("53 languages, Japanese and English included")
    func count() {
        #expect(LanguageCatalog.all.count == 53)
        #expect(LanguageCatalog.all.contains { $0.code == "ja" })
        #expect(LanguageCatalog.all.contains { $0.code == "en" })
        #expect(LanguageCatalog.all.contains { $0.code == "zh-hans" })
        #expect(LanguageCatalog.all.contains { $0.code == "zh-hant" })
    }

    @Test("codes are unique")
    func uniqueCodes() {
        let codes = Set(LanguageCatalog.all.map(\.code))
        #expect(codes.count == LanguageCatalog.all.count)
    }

    @Test("frequent languages come first, the rest are alphabetical")
    func menuOrder() {
        #expect(LanguageCatalog.frequent.map(\.code) == LanguageCatalog.frequentCodes)
        let others = LanguageCatalog.others
        #expect(others.count == 53 - LanguageCatalog.frequentCodes.count)
        #expect(others.allSatisfy { !LanguageCatalog.frequentCodes.contains($0.code) })
        let names = others.map(\.japaneseName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("names fall back to the code")
    func names() {
        #expect(LanguageCatalog.name(for: "ja") == "日本語")
        #expect(LanguageCatalog.name(for: "zh-hant") == "中国語（繁体）")
        #expect(LanguageCatalog.name(for: nil) == "自動")
        #expect(LanguageCatalog.name(for: "") == "自動")
        #expect(LanguageCatalog.name(for: "xx") == "xx")
    }

    @Test("recogniser identifiers are normalised")
    func normalisation() {
        #expect(LanguageCatalog.normalizedCode("en") == "en")
        #expect(LanguageCatalog.normalizedCode("ja") == "ja")
        #expect(LanguageCatalog.normalizedCode("zh") == "zh-hans")
        #expect(LanguageCatalog.normalizedCode("zh-Hans") == "zh-hans")
        #expect(LanguageCatalog.normalizedCode("zh-Hant") == "zh-hant")
        #expect(LanguageCatalog.normalizedCode("zh-TW") == "zh-hant")
        #expect(LanguageCatalog.normalizedCode("iw") == "he")
        #expect(LanguageCatalog.normalizedCode("in") == "id")
        #expect(LanguageCatalog.normalizedCode("fil") == "tl")
        #expect(LanguageCatalog.normalizedCode("pt") == nil)
        #expect(LanguageCatalog.normalizedCode("ru-RU") == "ru")
    }
}

@Suite("Language detection")
struct LanguageDetectorTests {
    @Test("a long English sentence is detected as English")
    func detectsEnglish() {
        let detection = LanguageDetector.detect("The quick brown fox jumps over the lazy dog and keeps running.")
        #expect(detection.code == "en")
    }

    @Test("a long Japanese sentence is detected as Japanese")
    func detectsJapanese() {
        let detection = LanguageDetector.detect("会議は来週の月曜日に変更されましたので、資料を先に送ってください。")
        #expect(detection.code == "ja")
    }

    @Test("a short weak guess keeps the previous language")
    func shortTextKeepsPrevious() {
        let result = LanguageDetector.resolve(
            text: "OK",
            previous: "fr",
            detect: { _ in LanguageDetector.Detection(code: "en", confidence: 0.2) }
        )
        #expect(result == "fr")
    }

    @Test("short Latin text after Japanese is not taken for Japanese")
    func shortLatinAfterJapanese() {
        let weakFrench = { (_: String) in LanguageDetector.Detection(code: "fr", confidence: 0.3) }
        let weakJapanese = { (_: String) in LanguageDetector.Detection(code: "ja", confidence: 0.3) }
        #expect(LanguageDetector.resolve(text: "hello", previous: "ja", detect: weakFrench) == "fr")
        #expect(LanguageDetector.resolve(text: "hello", previous: "ja", detect: weakJapanese) == "en")
        #expect(LanguageDetector.resolve(text: "hello", previous: "ko", detect: weakJapanese) == "en")
    }

    @Test("short text with kana is Japanese whatever came before")
    func shortKana() {
        let weakEnglish = { (_: String) in LanguageDetector.Detection(code: "en", confidence: 0.2) }
        #expect(LanguageDetector.resolve(text: "おはよう", previous: "en", detect: weakEnglish) == "ja")
        #expect(LanguageDetector.resolve(text: "API キー", previous: "en", detect: weakEnglish) == "ja")
    }

    @Test("short kanji keeps Chinese when Chinese came before, otherwise Japanese")
    func shortHan() {
        let weakEnglish = { (_: String) in LanguageDetector.Detection(code: "en", confidence: 0.2) }
        #expect(LanguageDetector.resolve(text: "翻訳", previous: "zh-hans", detect: weakEnglish) == "zh-hans")
        #expect(LanguageDetector.resolve(text: "翻訳", previous: "en", detect: weakEnglish) == "ja")
    }

    @Test("the letters a text is written in")
    func writingScript() {
        #expect(LanguageDetector.WritingScript.of("hello, world") == .latin)
        #expect(LanguageDetector.WritingScript.of("café") == .latin)
        #expect(LanguageDetector.WritingScript.of("漢字") == .han)
        #expect(LanguageDetector.WritingScript.of("カタカナ") == .kana)
        #expect(LanguageDetector.WritingScript.of("안녕") == .other)
        #expect(LanguageDetector.WritingScript.of("1234 !?") == .none)
    }

    @Test("a short confident guess is used")
    func shortTextConfident() {
        let result = LanguageDetector.resolve(
            text: "OK",
            previous: "ja",
            detect: { _ in LanguageDetector.Detection(code: "en", confidence: 0.9) }
        )
        #expect(result == "en")
    }

    @Test("a long text ignores the previous language")
    func longTextOverridesPrevious() {
        let long = String(repeating: "hello world ", count: 4)
        let result = LanguageDetector.resolve(
            text: long,
            previous: "ja",
            detect: { _ in LanguageDetector.Detection(code: "en", confidence: 0.1) }
        )
        #expect(result == "en")
    }

    @Test("with nothing recognised a short text falls back to the previous language")
    func nothingRecognised() {
        let result = LanguageDetector.resolve(
            text: "1234",
            previous: "ja",
            detect: { _ in LanguageDetector.Detection(code: nil, confidence: 0) }
        )
        #expect(result == "ja")
    }

    @Test("the default target is the other language")
    func defaultTarget() {
        #expect(LanguageDetector.defaultTarget(forSource: "ja") == "en")
        #expect(LanguageDetector.defaultTarget(forSource: "en") == "ja")
        #expect(LanguageDetector.defaultTarget(forSource: nil) == "ja")
        #expect(LanguageDetector.defaultTarget(forSource: "fr") == "ja")
    }
}
