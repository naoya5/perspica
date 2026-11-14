import Foundation

/// The stage names a PDF job shows (SPEC 8.2). The translator reports these
/// names directly; anything else (such as a stage saved by an older version)
/// shows as 「処理中」.
public enum PDFStage {
    public static let preparing = "準備中"
    public static let reading = "PDF を読み込み中"
    public static let layout = "レイアウトを解析中"
    public static let translating = "段落を翻訳中"
    public static let writing = "PDF を書き出し中"
    public static let unknown = "処理中"

    static let known: Set<String> = [preparing, reading, layout, translating, writing]

    public static func displayName(for stage: String) -> String {
        if stage.isEmpty { return preparing }
        return known.contains(stage) ? stage : unknown
    }
}
