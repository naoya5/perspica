import CoreGraphics
import Foundation
import Vision
import YakuCore

/// Reads text off a captured image with Vision (SPEC 9).
///
/// The recognised lines come back in image pixels with the origin at the top
/// left, which is the space `OCRBlockBuilder` and the overlay work in. Vision
/// itself reports normalised boxes with the origin at the bottom left, so the
/// conversion happens here and nowhere else.
enum ScreenOCR {
    enum OCRError: Error, Sendable {
        case failed(String)

        var message: String {
            switch self {
            case .failed(let text): text
            }
        }
    }

    /// Recognises text at the accuracy-first setting with language correction on
    /// (SPEC 9).
    static func lines(in image: CGImage, language: String?) async throws -> [OCRLine] {
        let requested = visionLanguage(for: language)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let requested {
                request.recognitionLanguages = [requested]
            } else {
                // 「自動」: let Vision work out the language itself.
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw OCRError.failed("\(error)")
            }

            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            var lines: [OCRLine] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
                lines.append(OCRLine(
                    text: candidate.string,
                    rect: rect,
                    confidence: Double(candidate.confidence)
                ))
            }
            return lines
        }.value
    }

    /// The lines grouped into blocks, ready to be translated.
    static func blocks(in image: CGImage, language: String?) async throws -> [OCRBlock] {
        OCRBlockBuilder.blocks(from: try await lines(in: image, language: language))
    }

    /// Maps a PLaMo language code onto the BCP-47 tag Vision wants. `auto` and
    /// anything unknown leave the choice to Vision.
    static func visionLanguage(for code: String?) -> String? {
        guard let code, !code.isEmpty, code != "auto" else { return nil }
        let table: [String: String] = [
            "ja": "ja-JP", "en": "en-US", "zh-hans": "zh-Hans", "zh-hant": "zh-Hant",
            "ko": "ko-KR", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT",
            "pt": "pt-BR", "ru": "ru-RU", "ar": "ar-SA", "hi": "hi-IN", "th": "th-TH",
            "vi": "vi-VN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL", "tr": "tr-TR",
            "uk": "uk-UA", "sv": "sv-SE", "da": "da-DK", "fi": "fi-FI", "no": "no-NO",
            "cs": "cs-CZ", "el": "el-GR", "he": "he-IL", "hu": "hu-HU", "ro": "ro-RO",
        ]
        return table[code] ?? code
    }
}
