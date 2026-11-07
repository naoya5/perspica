import CryptoKit
import Foundation

/// Streaming SHA-256 for a file on disk (SPEC 7.5: the download is checked
/// before it is used).
///
/// The file is read in chunks so a 5GB model never has to fit in memory.
public enum FileHash {
    public enum Failure: Error, Equatable {
        case unreadable(String)
    }

    public static let chunkSize = 1 << 20

    public static func sha256(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file's hash equals `expected` (case-insensitive).
    public static func matches(_ expected: String, fileAt url: URL) -> Bool {
        guard let digest = try? sha256(ofFileAt: url) else { return false }
        return digest.caseInsensitiveCompare(expected) == .orderedSame
    }
}
