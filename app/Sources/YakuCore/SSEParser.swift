import Foundation

/// Incremental reader for the `text/event-stream` body of
/// `POST /v1/completions`.
///
/// Bytes are buffered until a `\n` arrives, so a line that is split across
/// chunks (including a multi-byte UTF-8 character cut in half) is decoded only
/// once it is complete.
public struct SSEParser: Sendable {
    public enum Event: Equatable, Sendable {
        /// A `data:` payload, already trimmed. Never `[DONE]`.
        case data(String)
        /// `data: [DONE]`
        case done
    }

    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds raw bytes and returns every event completed by this chunk. A line
    /// is only emitted once its terminating newline has been fed, so callers
    /// must pass the newline along with the rest of the line.
    public mutating func feed(_ bytes: [UInt8]) -> [Event] {
        guard !bytes.isEmpty else { return [] }
        buffer.append(contentsOf: bytes)

        var events: [Event] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = Array(buffer[buffer.startIndex..<index])
            buffer.removeFirst(index - buffer.startIndex + 1)
            if let event = Self.parse(line: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Feeds text (convenience for tests and non-byte sources).
    public mutating func feed(_ chunk: String) -> [Event] {
        feed(Array(chunk.utf8))
    }

    /// Flushes a final line that arrived without a trailing newline.
    public mutating func finish() -> [Event] {
        guard !buffer.isEmpty else { return [] }
        let line = buffer
        buffer = []
        return Self.parse(line: line).map { [$0] } ?? []
    }

    /// Parses one already split line. Returns nil for comments, blank lines and
    /// every field other than `data`.
    public static func parse(line bytes: [UInt8]) -> Event? {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        guard line.hasPrefix("data:") else { return nil }

        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        payload = payload.trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return nil }
        if payload == "[DONE]" { return .done }
        return .data(payload)
    }

    /// Pulls `choices[0].text` out of one `data:` payload.
    public static func text(fromJSON payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let text = choices.first?["text"] as? String
        else { return nil }
        return text
    }
}
