import Foundation

/// The Japanese name of a BabelDOC stage (SPEC 8.2).
///
/// pdf2zh-next reports the stage in English; the app shows these five names and
/// falls back to 「処理中」 for anything it does not know. The order of the
/// checks matters: "Parse Page Layout" contains both "parse" and "layout" and
/// belongs to the layout stage, and "Subset font" contains "font" but is part
/// of writing the PDF out.
public enum PDFStage {
    public static let preparing = "準備中"
    public static let reading = "PDF を読み込み中"
    public static let layout = "レイアウトを解析中"
    public static let translating = "段落を翻訳中"
    public static let writing = "PDF を書き出し中"
    public static let unknown = "処理中"

    public static func japaneseName(for stage: String) -> String {
        let name = stage.lowercased()
        if name.isEmpty { return preparing }
        if name.contains("prepar") || name.contains("warm") { return preparing }
        if name.contains("translat") { return translating }
        if name.contains("typeset") || name.contains("save") || name.contains("subset")
            || name.contains("render") || name.contains("write") || name.contains("output")
            || name.contains("generat") {
            return writing
        }
        if name.contains("layout") { return layout }
        if name.contains("parse") || name.contains("load") || name.contains("read")
            || name.contains("extract") || name.contains("font") || name.contains("scan")
            || name.contains("table") || name.contains("formula") || name.contains("descent")
            || name.contains("term") {
            return reading
        }
        return unknown
    }
}
