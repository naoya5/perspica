import Foundation

/// Splits a byte stream into lines, safely from a background readability
/// handler. Used by the PDF worker's stdout reader and by the installer's
/// `uv` output reader.
public final class LineSplitter: @unchecked Sendable {
    public init() {}

    private var buffer = Data()
    private let lock = NSLock()

    /// Appends `data` and returns every complete line it completed.
    public func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let line = String(data: Data(lineData), encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}
