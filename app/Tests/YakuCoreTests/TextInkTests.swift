import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import YakuCore

/// Draws a line of text the way a screen shows it, and hands back the picture
/// and the ink's own box, which is what Vision's line box is close to.
private func draw(
    _ text: String,
    size: CGFloat,
    scale: CGFloat = 1,
    bold: Bool = false,
    canvas: CGSize = CGSize(width: 420, height: 90),
    at origin: CGPoint = CGPoint(x: 12, y: 24)
) -> (image: PixelImage, ink: CGRect) {
    let width = Int(canvas.width * scale)
    let height = Int(canvas.height * scale)
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)

    let font = CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: bold ? CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font : font,
        .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    context.textPosition = origin
    CTLineDraw(line, context)

    let image = PixelImage(cgImage: context.makeImage()!)!
    return (image, inkBox(in: image))
}

/// The box around every dark pixel, in image pixels.
private func inkBox(in image: PixelImage) -> CGRect {
    var minX = image.width, maxX = -1, minY = image.height, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width where image.luminance(x: x, y: y) < 0.5 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@Suite("Text ink")
struct TextInkTests {
    /// The sizes the samples actually use: 12 for a row's
    /// description, 14 for a sidebar label, 15 for a row's title and 40 for the
    /// article's heading.
    private static let sizes: [CGFloat] = [12, 13, 14, 15, 17, 19, 34, 40]

    @Test("the band gives back the size the text was drawn at", arguments: [1.0, 2.0] as [CGFloat])
    func sizeFollowsTheBand(scale: CGFloat) throws {
        // A band of `b` pixels holds `b / 0.5311` points, so one whole pixel is
        // worth 8% of a 12-point size at 1× and 4% at 2×. That rounding is the
        // whole of the error at 2× (measured: within 3.4% over these sizes) and
        // most of it at 1× (within 11%), where a partly covered edge row counts
        // as ink or does not.
        let bar: CGFloat = scale >= 2 ? 0.05 : 0.12
        for size in Self.sizes {
            let (image, ink) = draw("Settings", size: size, scale: scale)
            let measured = try #require(TextInk.fontSize(in: image, line: ink, pointsPerPixel: 1 / scale))
            #expect(abs(measured - size) / size < bar,
                    "drew \(size)pt at \(scale)×, measured \(measured)pt")
        }
    }

    @Test("the same size measures the same from a whole-picture pass and a tile")
    func cropDoesNotChangeTheSize() throws {
        // Vision's box for one line differs by 15–19% between the whole-picture
        // pass and a tile, which is what made a sidebar's labels
        // come out at 9.5 and 13.8 points for one 14-point size. The ink band
        // is read from the pixels, so the crop cannot move it.
        let tight = draw("General", size: 14)
        let padded = draw("General", size: 14)
        let paddedBox = padded.ink.insetBy(dx: -4, dy: -4)
        let tightSize = try #require(TextInk.fontSize(in: tight.image, line: tight.ink))
        let paddedSize = try #require(TextInk.fontSize(in: padded.image, line: paddedBox))
        #expect(abs(tightSize - paddedSize) < 0.2, "\(tightSize) vs \(paddedSize)")

        // A tile is the picture cropped around the line: the band inside the
        // line's box is unchanged.
        let region = paddedBox.insetBy(dx: -30, dy: -20)
        let origin = CGPoint(x: max(0, region.minX), y: max(0, region.minY))
        let tile = try #require(crop(tight.image, to: region))
        let tileBox = tight.ink.offsetBy(dx: -origin.x, dy: -origin.y)
        let tileSize = try #require(TextInk.fontSize(in: tile, line: tileBox))
        #expect(abs(tightSize - tileSize) < 0.2, "\(tightSize) vs \(tileSize)")
    }

    @Test("the box only has to hold the line, not match its ink")
    func boxNeedNotBeExact() throws {
        let (image, ink) = draw("Privacy", size: 14)
        let measured = try #require(TextInk.fontSize(in: image, line: ink))
        // Vision's box is a little loose on both sides.
        let loose = try #require(TextInk.fontSize(in: image, line: ink.insetBy(dx: -6, dy: -3)))
        #expect(abs(measured - loose) < 0.3)
    }

    @Test("the boxes the two passes really reported give one size")
    func theRealBoxes() throws {
        // The UI sample's sidebar, drawn at 14 points: `General` came back in a
        // 16.5-pixel box from the whole-picture pass and a 12.4-pixel box from a
        // tile, and the overlay drew the two at 13.8 and 10.4 points.
        // Both boxes hold the same ink, so the band is the same.
        let (image, ink) = draw("General", size: 14)
        func box(height: CGFloat) -> CGRect {
            ink.insetBy(dx: -3, dy: -(height - ink.height) / 2)
        }
        let whole = try #require(TextInk.fontSize(in: image, line: box(height: 16.5)))
        let tile = try #require(TextInk.fontSize(in: image, line: box(height: 12.4)))
        #expect(abs(whole - tile) < 0.2, "\(whole) vs \(tile)")
        #expect(abs(whole - 14) / 14 < 0.12, "measured \(whole) for a 14-point line")
    }

    @Test("a bigger size measures bigger")
    func ordering() throws {
        // Sizes three points apart or more: at 1× a 12- and a 13-point line both
        // come out as a 7.2-pixel band, which is the resolution of the picture
        // rather than of the rule.
        for scale in [1.0, 2.0] as [CGFloat] {
            var previous: CGFloat = 0
            for size in [12, 15, 19, 34, 40] as [CGFloat] {
                let (image, ink) = draw("Settings", size: size, scale: scale)
                let measured = try #require(TextInk.fontSize(in: image, line: ink, pointsPerPixel: 1 / scale))
                #expect(measured > previous, "\(size)pt at \(scale)× measured \(measured)")
                previous = measured
            }
        }
    }

    @Test("light text on a dark screen measures the same as dark on light")
    func lightOnDark() throws {
        let (image, ink) = draw("Settings", size: 14)
        // Invert the picture: the ink rule has to notice which way round it is.
        var pixels = image.pixels
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 255 - pixels[offset]
            pixels[offset + 1] = 255 - pixels[offset + 1]
            pixels[offset + 2] = 255 - pixels[offset + 2]
        }
        let inverted = PixelImage(width: image.width, height: image.height, pixels: pixels)
        let dark = try #require(TextInk.fontSize(in: image, line: ink))
        let light = try #require(TextInk.fontSize(in: inverted, line: ink))
        #expect(abs(dark - light) < 0.3, "\(dark) vs \(light)")
    }

    @Test("an empty box has no size to report")
    func emptyBox() {
        let (image, _) = draw("", size: 14)
        #expect(TextInk.fontSize(in: image, line: CGRect(x: 5, y: 5, width: 40, height: 20)) == nil)
        #expect(TextInk.fontSize(forBand: 2) == nil)
    }

    // MARK: measuring from the width of the ink

    /// The sizes the samples draw their text at, and lines long
    /// enough that one pixel of edge does not matter.
    private static let widthCases: [(String, CGFloat)] = [
        ("The dominant sequence transduction models", 19),
        ("Show in Lock Screen", 15),
        ("Keep recent items visible", 12),
        ("エンコーダは、同一の層が6層積層された構成", 17),
        ("混ざった段落", 34),
    ]

    @Test("the width of the ink gives back the size the text was drawn at", arguments: [1.0, 2.0] as [CGFloat])
    func widthFollowsTheSize(scale: CGFloat) throws {
        // Measured on the samples themselves: exact to within 0.3% for Latin
        // text at 13–19 points and for Japanese text at 17. The
        // answer comes back in the picture's own pixels, so at 2× it is twice
        // the point size. The margin leaves room for a partly covered edge
        // pixel.
        for (text, size) in Self.widthCases {
            let (image, ink) = draw(text, size: size, scale: scale)
            let pixels = try #require(TextInk.fontSize(
                in: image, line: ink, text: text, pointsPerPixel: 1 / scale))
            #expect(abs(pixels / scale - size) / size < 0.04,
                    "drew \(size)pt at \(scale)×, measured \(pixels / scale)pt: \(text)")
        }
    }

    @Test("the width is solved in points, so a 2× picture reads the same size")
    func widthSolvesInPoints() throws {
        // The system font switches to narrower Display metrics above 20 points,
        // so solving in a 2× picture's own pixels reads 12-point text about 8%
        // high. Passing the picture's scale is what avoids that.
        let (image, ink) = draw("Keep recent items visible", size: 12, scale: 2)
        let naive = try #require(TextInk.fontSize(in: image, line: ink, text: "Keep recent items visible"))
        let scaled = try #require(TextInk.fontSize(
            in: image, line: ink, text: "Keep recent items visible", pointsPerPixel: 0.5))
        #expect(naive / 2 > 12 * 1.05, "\(naive / 2)")
        #expect(abs(scaled / 2 - 12) / 12 < 0.02, "\(scaled / 2)")
    }

    @Test("the width reads Japanese and English text at one size the same")
    func widthIsTheSameForEveryScript() throws {
        // This is why the split rule compares widths and not ink bands: the
        // band follows the x-height, so it reads the Japanese line of a mixed
        // sample 35–46% larger than the English one at the same size, and a paragraph would
        // split at every script change.
        let japanese = draw("エンコーダは、同一の層が6層積層された構成", size: 17)
        let english = draw("We employ a residual connection", size: 17)
        let japaneseWidth = try #require(TextInk.fontSize(
            in: japanese.image, line: japanese.ink, text: "エンコーダは、同一の層が6層積層された構成"))
        let englishWidth = try #require(TextInk.fontSize(
            in: english.image, line: english.ink, text: "We employ a residual connection"))
        #expect(abs(japaneseWidth - englishWidth) / englishWidth < 0.03,
                "\(japaneseWidth) vs \(englishWidth)")
        // The band does not: it is what the two would have been compared with.
        let japaneseBand = try #require(TextInk.fontSize(in: japanese.image, line: japanese.ink))
        let englishBand = try #require(TextInk.fontSize(in: english.image, line: english.ink))
        #expect(japaneseBand > englishBand * 1.25, "band \(japaneseBand) vs \(englishBand)")
    }

    @Test("the width does not change with the size of the crop around it")
    func widthIgnoresTheCrop() throws {
        let (image, ink) = draw("Show in Lock Screen", size: 15)
        let tight = try #require(TextInk.fontSize(in: image, line: ink, text: "Show in Lock Screen"))
        let loose = try #require(TextInk.fontSize(
            in: image, line: ink.insetBy(dx: -6, dy: -3), text: "Show in Lock Screen"))
        #expect(abs(tight - loose) < 0.3, "\(tight) vs \(loose)")
    }

    @Test("the width measures light text on a dark screen the same")
    func widthLightOnDark() throws {
        let (image, ink) = draw("Play a sound", size: 15)
        var pixels = image.pixels
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 255 - pixels[offset]
            pixels[offset + 1] = 255 - pixels[offset + 1]
            pixels[offset + 2] = 255 - pixels[offset + 2]
        }
        let inverted = PixelImage(width: image.width, height: image.height, pixels: pixels)
        let dark = try #require(TextInk.fontSize(in: image, line: ink, text: "Play a sound"))
        let light = try #require(TextInk.fontSize(in: inverted, line: ink, text: "Play a sound"))
        #expect(abs(dark - light) < 0.3, "\(dark) vs \(light)")
    }

    @Test("a wider ink means a larger size")
    func widthOrdering() throws {
        var previous: CGFloat = 0
        for size in [12, 15, 19, 34, 40] as [CGFloat] {
            let measured = try #require(TextInk.fontSize(
                fromInkWidth: TextInk.unitWidth("Settings", size: size), text: "Settings"))
            #expect(abs(measured - size) < 0.05, "\(size) came back as \(measured)")
            #expect(measured > previous)
            previous = measured
        }
    }

    @Test("there is no size to report without text or without ink")
    func widthNeedsText() throws {
        let (image, ink) = draw("Settings", size: 14)
        #expect(TextInk.fontSize(in: image, line: ink, text: "") == nil)
        #expect(TextInk.fontSize(fromInkWidth: 0, text: "Settings") == nil)
        #expect(TextInk.fontSize(fromInkWidth: 100, text: "") == nil)
        #expect(TextInk.unitWidth("", size: 14) == 0)
        // Ink too wide for any size in the search: reported as nil, not as the
        // top of the range.
        #expect(TextInk.fontSize(fromInkWidth: 100_000, text: "Settings") == nil)
        // A box with no ink at all has nothing to measure.
        #expect(TextInk.fontSize(
            in: image, line: CGRect(x: 5, y: 5, width: 4, height: 4), text: "Settings") == nil)
    }
}

/// The same picture, cropped to `rect`, with the origin moved to its corner.
private func crop(_ image: PixelImage, to rect: CGRect) -> PixelImage? {
    let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
    let x1 = min(image.width, Int(rect.maxX)), y1 = min(image.height, Int(rect.maxY))
    guard x1 > x0, y1 > y0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
    for y in y0..<y1 {
        for x in x0..<x1 {
            let from = (y * image.width + x) * 4
            let to = ((y - y0) * (x1 - x0) + (x - x0)) * 4
            pixels[to] = image.pixels[from]
            pixels[to + 1] = image.pixels[from + 1]
            pixels[to + 2] = image.pixels[from + 2]
            pixels[to + 3] = image.pixels[from + 3]
        }
    }
    return PixelImage(width: x1 - x0, height: y1 - y0, pixels: pixels)
}
