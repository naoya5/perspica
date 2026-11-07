import Foundation

/// CSV import and export for the glossary (SPEC 4.4, 11).
///
/// The format is `source,target,enabled` with a header row. Fields are quoted
/// only when they need to be, and a quoted field's `"` is doubled, so a term
/// containing a comma or a quote survives a round trip.
public enum GlossaryCSV {
    public struct Row: Sendable, Equatable {
        public let source: String
        public let target: String
        public let enabled: Bool

        public init(source: String, target: String, enabled: Bool = true) {
            self.source = source
            self.target = target
            self.enabled = enabled
        }
    }

    public static let header = "source,target,enabled"

    public static func encode(_ rows: [Row]) -> String {
        var lines = [header]
        for row in rows {
            lines.append([
                field(row.source),
                field(row.target),
                row.enabled ? "true" : "false",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses rows, skipping the header when present and dropping rows with an
    /// empty source. Unparseable `enabled` values default to true.
    public static func parse(_ text: String) -> [Row] {
        // Swift treats CRLF as a single Character, so the line breaks are
        // normalised before the parser sees them.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [Row] = []
        for (index, record) in records(in: normalized).enumerated() {
            guard record.count >= 2 else { continue }
            let source = record[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let target = record[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            if index == 0, source.lowercased() == "source", target.lowercased() == "target" {
                continue
            }
            let enabled = record.count >= 3 ? parseBool(record[2]) : true
            rows.append(Row(source: source, target: target, enabled: enabled))
        }
        return rows
    }

    private static func parseBool(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "false", "0", "no", "off", "無効": false
        default: true
        }
    }

    private static func field(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Splits the text into records of fields, honouring quoted fields.
    private static func records(in text: String) -> [[String]] {
        var result: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if next == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    quoted = true
                case ",":
                    record.append(field)
                    field = ""
                case "\r":
                    break
                case "\n":
                    record.append(field)
                    result.append(record)
                    record = []
                    field = ""
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            result.append(record)
        }
        return result
    }
}
