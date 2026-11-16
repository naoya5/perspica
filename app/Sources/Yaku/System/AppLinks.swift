import Foundation

/// Where Perspica lives on the web. The app only opens these in the browser;
/// it never fetches them itself (the model download is its only network use).
enum AppLinks {
    static let repository = URL(string: "https://github.com/naoya5/perspica")!
    /// Every published version, newest first. "新しい版を確認…" opens it.
    static let releases = URL(string: "https://github.com/naoya5/perspica/releases")!

    /// The version a person compares with the releases page, for example "0.1.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
    }
}
