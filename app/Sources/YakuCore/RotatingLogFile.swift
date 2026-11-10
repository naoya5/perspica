import Foundation

/// A bounded byte log. The caller serializes access across append/rotate/clear.
/// Writes are split before rotation, including a single oversized pipe read.
public enum RotatingLogFile {
    public static let maximumBytes: UInt64 = 5 * 1024 * 1024
    public static let keptFiles = 3

    public static func archive(of url: URL, index: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(index)")
    }

    private static func size(_ url: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private static func rotate(_ url: URL) throws {
        let manager = FileManager.default
        let oldest = archive(of: url, index: keptFiles - 1)
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: keptFiles - 2, through: 1, by: -1) {
            let from = archive(of: url, index: index)
            if manager.fileExists(atPath: from.path) {
                try manager.moveItem(at: from, to: archive(of: url, index: index + 1))
            }
        }
        if manager.fileExists(atPath: url.path) {
            try manager.moveItem(at: url, to: archive(of: url, index: 1))
        }
    }

    /// Migrate a log left oversized by an older version without an unbounded
    /// allocation. Only the newest three files' worth remains, as on append.
    public static func rotateIfNeeded(_ url: URL) throws {
        let count = try size(url)
        guard count > maximumBytes else { return }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: count > maximumBytes * UInt64(keptFiles)
            ? count - maximumBytes * UInt64(keptFiles) : 0)
        // The read handle keeps the old inode alive after unlinking.
        try FileManager.default.removeItem(at: url)
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try append(data, to: url)
        }
    }

    public static func append(_ data: Data, to url: URL) throws {
        guard !data.isEmpty else { return }
        try rotateIfNeeded(url)
        var offset = 0
        while offset < data.count {
            var count = try size(url)
            if count >= maximumBytes {
                try rotate(url)
                count = 0
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let length = min(data.count - offset, Int(maximumBytes - count))
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length)))
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            offset += length
        }
    }
}
