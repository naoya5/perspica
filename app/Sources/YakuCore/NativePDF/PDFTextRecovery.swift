import CoreGraphics
import Foundation
import PDFKit

/// Fills in the text of glyphs whose font gives no Unicode mapping.
///
/// Quartz writes Japanese fonts as CID fonts without a ToUnicode map, so the
/// font alone cannot say which character a code is. PDFKit can (macOS ships the
/// character collections), so each unmapped glyph takes the character PDFKit
/// reports at the same place on the page.
public enum PDFTextRecovery {
    /// Returns how many glyphs were filled.
    @discardableResult
    public static func fill(_ glyphs: inout [PDFGlyph], from page: PDFPage) -> Int {
        let missing = glyphs.indices.filter {
            glyphs[$0].unicode.isEmpty && glyphs[$0].renderMode != 3 && glyphs[$0].renderMode != 7
        }
        guard !missing.isEmpty, let text = page.string, !text.isEmpty else { return 0 }

        // PDFKit's character indices are UTF-16 offsets into `page.string`.
        let units = Array(text.utf16)
        var characters: [(box: CGRect, text: String)] = []
        var offset = 0
        while offset < units.count {
            let length = UTF16.isLeadSurrogate(units[offset]) && offset + 1 < units.count ? 2 : 1
            let box = page.characterBounds(at: offset)
            if box.width > 0, box.height > 0,
               let character = String(utf16CodeUnits: Array(units[offset..<offset + length]), count: length) as String?,
               !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                characters.append((box, character))
            }
            offset += length
        }
        guard !characters.isEmpty else { return 0 }

        var filled = 0
        for index in missing {
            let glyph = glyphs[index].bounds
            let center = CGPoint(x: glyph.midX, y: glyph.midY)
            // The character box that contains the glyph centre, else the nearest one close by.
            var best: (distance: CGFloat, text: String)?
            for character in characters {
                if character.box.insetBy(dx: -0.5, dy: -0.5).contains(center) {
                    best = (0, character.text)
                    break
                }
                let distance = hypot(character.box.midX - center.x, character.box.midY - center.y)
                if distance < max(glyph.height, 1) * 0.5, distance < (best?.distance ?? .infinity) {
                    best = (distance, character.text)
                }
            }
            if let best {
                glyphs[index].unicode = best.text
                filled += 1
            }
        }
        return filled
    }
}
