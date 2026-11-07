import Foundation

/// The launch arguments the path and settings layers need before anything else
/// runs (SPEC 15).
///
/// These are read straight from `CommandLine.arguments` rather than through
/// `DemoOptions`, because `AppPaths` and `AppSettings` may be touched while the
/// SwiftUI scenes are being built, before the delegate sees a notification.
enum LaunchArguments {
    /// `--data-dir <folder>`: use this folder instead of Application Support.
    static let dataDirectory: String? = value(for: "--data-dir")

    static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        let value = arguments[next]
        return value.hasPrefix("--") ? nil : value
    }
}
