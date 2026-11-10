// Strict size bounds for the rotating logs, checked at the exact byte
// boundary and with single writes far larger than one file.
import Foundation
import Testing
@testable import YakuCore

@Suite("RotatingLogFile", .serialized)
struct RotatingLogFileTests {
    static let limit = Int(RotatingLogFile.maximumBytes)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bytes(_ count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed) % 251) })
    }

    private func sizes(_ log: URL) -> [Int?] {
        [log, RotatingLogFile.archive(of: log, index: 1), RotatingLogFile.archive(of: log, index: 2),
         RotatingLogFile.archive(of: log, index: 3)].map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        }
    }

    /// Oldest first: `.2`, `.1`, then the current file.
    private func joined(_ log: URL) -> Data {
        var out = Data()
        for url in [RotatingLogFile.archive(of: log, index: 2), RotatingLogFile.archive(of: log, index: 1), log] {
            if let data = try? Data(contentsOf: url) { out.append(data) }
        }
        return out
    }

    @Test("exactly 5 MB stays in one file; the next byte opens a new one")
    func boundary() throws {
        let log = try folder().appendingPathComponent("app.log")
        try RotatingLogFile.append(bytes(Self.limit - 1), to: log)
        try RotatingLogFile.append(bytes(1, seed: 7), to: log)
        #expect(sizes(log) == [Self.limit, nil, nil, nil])
        try RotatingLogFile.append(bytes(1, seed: 9), to: log)
        #expect(sizes(log) == [1, Self.limit, nil, nil])
    }

    @Test("one write larger than two files is split, never over 5 MB, nothing lost")
    func oversizedWrite() throws {
        let log = try folder().appendingPathComponent("engine.log")
        let data = bytes(2 * Self.limit + 7)
        try RotatingLogFile.append(data, to: log)
        #expect(sizes(log) == [7, Self.limit, Self.limit, nil])
        #expect(joined(log) == data)
    }

    @Test("a write larger than three files keeps exactly the newest 15 MB")
    func overflowKeepsNewest() throws {
        let log = try folder().appendingPathComponent("pdf.log")
        try RotatingLogFile.append(bytes(1000, seed: 3), to: log)
        let data = bytes(4 * Self.limit + 123, seed: 5)
        try RotatingLogFile.append(data, to: log)
        let s = sizes(log)
        #expect(s[3] == nil)
        for size in s.compactMap({ $0 }) { #expect(size <= Self.limit) }
        // 1000 + 4L + 123 bytes fill L-sized files; the older 1000 bytes and
        // the first two files of the write are rotated out.
        #expect(s == [1123, Self.limit, Self.limit, nil])
        #expect(joined(log) == data.suffix(2 * Self.limit + 1123))
    }

    @Test("many small writes across the boundary never exceed 5 MB per file")
    func smallWrites() throws {
        let log = try folder().appendingPathComponent("app.log")
        let line = bytes(4093, seed: 1)
        var written = Data()
        for _ in 0..<(Self.limit / line.count + 3) {
            try RotatingLogFile.append(line, to: log)
            written.append(line)
            let s = sizes(log)
            #expect(s.compactMap { $0 }.allSatisfy { $0 <= Self.limit })
        }
        #expect(sizes(log)[1] == Self.limit)
        #expect(joined(log) == written)
    }

    @Test("an oversized file from an older version is split on rotation, newest 15 MB kept")
    func legacyOversized() throws {
        let log = try folder().appendingPathComponent("app.log")
        let data = bytes(3 * Self.limit + 4321, seed: 11)
        try data.write(to: log)
        try RotatingLogFile.rotateIfNeeded(log)
        let s = sizes(log)
        #expect(s.compactMap { $0 }.allSatisfy { $0 <= Self.limit })
        #expect(s[3] == nil)
        #expect(joined(log) == data.suffix(3 * Self.limit))
    }

    @Test("a log at or under 5 MB is left alone at launch")
    func underLimitUntouched() throws {
        let log = try folder().appendingPathComponent("app.log")
        try bytes(Self.limit).write(to: log)
        try RotatingLogFile.rotateIfNeeded(log)
        #expect(sizes(log) == [Self.limit, nil, nil, nil])
    }
}
