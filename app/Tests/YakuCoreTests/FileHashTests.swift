import CryptoKit
import Foundation
import Testing
@testable import YakuCore

@Suite("File SHA-256")
struct FileHashTests {
    /// Writes the bytes to a temporary file and returns its URL.
    private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaku-hash-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("the empty file hashes to the well known digest")
    func emptyFile() throws {
        let url = try temporaryFile([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FileHash.sha256(ofFileAt: url)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("abc hashes to the well known digest")
    func abc() throws {
        let url = try temporaryFile(Array("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FileHash.sha256(ofFileAt: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("a file larger than one chunk is read to the end")
    func multiChunk() throws {
        // 2.5 chunks of a repeating pattern, so the last read is partial.
        let size = FileHash.chunkSize * 2 + FileHash.chunkSize / 2
        let bytes = (0..<size).map { UInt8($0 % 251) }
        let url = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try FileHash.sha256(ofFileAt: url)
        #expect(digest.count == 64)
        // Same bytes, hashed in one go.
        let expected = SHA256Digest.of(Data(bytes))
        #expect(digest == expected)
    }

    @Test("matches compares case-insensitively and reports a mismatch")
    func matches() throws {
        let url = try temporaryFile(Array("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileHash.matches("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", fileAt: url))
        #expect(!FileHash.matches("deadbeef", fileAt: url))
    }

    @Test("a missing file throws instead of reporting a digest")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaku-hash-missing-\(UUID().uuidString).bin")
        #expect(throws: FileHash.Failure.self) {
            _ = try FileHash.sha256(ofFileAt: url)
        }
    }
}

/// A plain one-shot SHA-256, so the streaming implementation is compared
/// against something that does not share its code.
enum SHA256Digest {
    static func of(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
