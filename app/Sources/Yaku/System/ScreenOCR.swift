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
    ///
    /// Vision misses small text on a large capture, and a Retina capture is
    /// several thousand pixels across, so a second, tiled pass fills in what the
    /// whole-picture pass left out (`OCRTiling`). The whole-picture pass is kept
    /// as the base because it reads long lines whole; the tiles only contribute
    /// lines the whole-picture pass did not report at all.
    ///
    /// The two passes are separate so the caller can lay the first one over the
    /// screen and start translating it while the tiles are still being read:
    /// run together, three Vision passes take about 0.9s on a 1440×900 capture
    /// and the first block misses SPEC 9's one second (M5.md 3.4). Use
    /// `wholeLines` and `recoveredLines` for that; this combined call is for the
    /// paths that want the finished answer in one go.
    static func lines(in image: CGImage, language: String?) async throws -> [OCRLine] {
        let whole = try await wholeLines(in: image, language: language)
        let recovered = try await recoveredLines(in: image, language: language)
        return OCRTiling.mergeRecovered(base: whole, extra: recovered)
    }

    /// The whole-picture pass: long lines read as a whole, small text missed.
    static func wholeLines(in image: CGImage, language: String?) async throws -> [OCRLine] {
        let requested = visionLanguage(for: language)
        guard !OCRTiling.tiles(width: image.width, height: image.height).isEmpty else { return [] }
        return try recognize(in: image, language: requested, offset: .zero)
    }

    /// The tiled passes, merged into one set of lines. Empty when the picture is
    /// small enough to need only the whole-picture pass.
    static func recoveredLines(in image: CGImage, language: String?) async throws -> [OCRLine] {
        let requested = visionLanguage(for: language)
        let tiles = OCRTiling.tiles(width: image.width, height: image.height)
        guard tiles.count > 1 else { return [] }

        return try await withThrowingTaskGroup(of: [OCRLine].self) { group in
            for tile in tiles {
                guard let piece = image.cropping(to: tile) else { continue }
                group.addTask(priority: .userInitiated) {
                    try recognize(in: piece, language: requested, offset: tile.origin)
                }
            }
            var found: [[OCRLine]] = []
            for try await lines in group { found.append(lines) }
            return OCRTiling.merge(found)
        }
    }

    /// One Vision pass over one tile, with the lines moved into the whole
    /// picture's coordinates.
    private static func recognize(
        in image: CGImage,
        language: String?,
        offset: CGPoint
    ) throws -> [OCRLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language {
            request.recognitionLanguages = [language]
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
                x: box.minX * width + offset.x,
                y: (1 - box.maxY) * height + offset.y,
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
