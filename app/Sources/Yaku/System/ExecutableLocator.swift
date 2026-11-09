import Foundation

/// Finds a command-line tool the app depends on (`llama-server`, `uv`).
///
/// An app opened from Finder does not inherit the shell's `PATH`, so the
/// usual install locations are searched in order: Homebrew on Apple silicon,
/// Homebrew on Intel and other `/usr/local` installs, then uv's own installer.
enum ExecutableLocator {
    static let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
    ]

    static func find(_ name: String) -> String? {
        searchDirectories
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
