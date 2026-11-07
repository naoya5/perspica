import Foundation

/// One line of the PDF worker's stdout (SPEC 8.2).
public enum PDFWorkerEvent: Equatable, Sendable {
    /// `{"type":"progress","progress":0.42,"stage":"Translate Paragraphs"}`
    case progress(value: Double, stage: String)
    /// `{"type":"done","mono":"…","dual":"…","seconds":12.3}`
    case done(mono: String, dual: String, seconds: Double)
    /// `{"type":"error","message":"…"}`
    case error(message: String)
}

/// Reads the newline-delimited JSON the worker writes.
///
/// Anything that is not one of the three events is ignored rather than
/// reported: the worker keeps its own stdout clean, but a stray line should
/// never turn into a user-facing error.
public enum PDFWorkerLine {
    public static func parse(_ line: String) -> PDFWorkerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "progress":
            let value = number(object["progress"]) ?? 0
            let stage = object["stage"] as? String ?? ""
            return .progress(value: value, stage: stage)
        case "done":
            return .done(
                mono: object["mono"] as? String ?? "",
                dual: object["dual"] as? String ?? "",
                seconds: number(object["seconds"]) ?? 0
            )
        case "error":
            return .error(message: object["message"] as? String ?? "unknown error")
        default:
            return nil
        }
    }

    /// Accepts an integer or a floating-point number, because JSON has one
    /// number type and the worker can emit either.
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
