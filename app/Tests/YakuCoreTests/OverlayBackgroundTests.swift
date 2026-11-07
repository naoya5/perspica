import CoreGraphics
import Foundation
import Testing
@testable import YakuCore

/// Builds an RGBA8 image, painting `ink` rectangles over a flat background.
private func image(
    width: Int,
    height: Int,
    background: RGBColor,
    ink: [(CGRect, RGBColor)] = []
) -> PixelImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    func set(_ x: Int, _ y: Int, _ color: RGBColor) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8((color.red * 255).rounded())
        pixels[offset + 1] = UInt8((color.green * 255).rounded())
        pixels[offset + 2] = UInt8((color.blue * 255).rounded())
        pixels[offset + 3] = 255
    }
    for y in 0..<height {
        for x in 0..<width { set(x, y, background) }
    }
    for (rect, color) in ink {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) { set(x, y, color) }
        }
    }
    return PixelImage(width: width, height: height, pixels: pixels)
}

private let black = RGBColor.black
private let white = RGBColor.white

@Suite("Overlay background colour")
struct OverlayBackgroundTests {
    @Test("a light page with dark text reads white behind and black inside")
    func lightPage() {
        let block = CGRect(x: 50, y: 40, width: 100, height: 20)
        let page = image(width: 200, height: 100, background: white, ink: [(block, black)])
        let background = OverlayBackground.color(in: page, around: block)
        #expect(background.luminance > 0.95)
        let text = OverlayBackground.textColor(in: page, block: block, background: background)
        #expect(text.luminance < 0.05)
    }

    @Test("a dark screen with light text reads dark behind and white inside")
    func darkScreen() {
        let dark = RGBColor(red: 0.08, green: 0.09, blue: 0.11)
        let block = CGRect(x: 60, y: 30, width: 120, height: 24)
        let screen = image(width: 240, height: 120, background: dark, ink: [(block, white)])
        let background = OverlayBackground.color(in: screen, around: block)
        #expect(background.luminance < 0.2)
        let text = OverlayBackground.textColor(in: screen, block: block, background: background)
        #expect(text.luminance > 0.9)
    }

    @Test("a stray dark pixel in the ring does not change the background")
    func medianIgnoresOutliers() {
        let block = CGRect(x: 50, y: 50, width: 100, height: 30)
        var page = image(width: 200, height: 130, background: white)
        // A few black specks just outside the block.
        page = PixelImage(width: page.width, height: page.height, pixels: {
            var pixels = page.pixels
            for x in 48..<52 {
                let offset = (48 * page.width + x) * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            }
            return pixels
        }())
        let background = OverlayBackground.color(in: page, around: block)
        #expect(background.luminance > 0.9)
    }

    @Test("a block that covers the whole image falls back to the pixels it has")
    func blockCoversImage() {
        let gray = RGBColor(red: 0.4, green: 0.4, blue: 0.4)
        let whole = image(width: 40, height: 40, background: gray)
        let background = OverlayBackground.color(in: whole, around: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(abs(background.luminance - gray.luminance) < 0.05)
    }

    @Test("a block with no readable ink falls back to black or white")
    func unreadableInk() {
        let mid = RGBColor(red: 0.5, green: 0.5, blue: 0.5)
        let barely = RGBColor(red: 0.55, green: 0.55, blue: 0.55)
        let block = CGRect(x: 20, y: 20, width: 60, height: 20)
        let page = image(width: 100, height: 60, background: mid, ink: [(block, barely)])
        let background = OverlayBackground.color(in: page, around: block)
        let text = OverlayBackground.textColor(in: page, block: block, background: background)
        #expect(text == OverlayBackground.contrasting(against: background))
    }

    @Test("contrasting picks black on light and white on dark")
    func contrasting() {
        #expect(OverlayBackground.contrasting(against: white) == .black)
        #expect(OverlayBackground.contrasting(against: RGBColor(red: 0.05, green: 0.05, blue: 0.05)) == .white)
        #expect(OverlayBackground.contrasting(against: RGBColor(red: 0.5, green: 0.5, blue: 0.5)) == .black)
    }

    @Test("a captured CGImage is redrawn into RGBA8 and read back")
    func fromCGImage() {
        let context = CGContext(
            data: nil,
            width: 20,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        context?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 20, height: 5))
        guard let cgImage = context?.makeImage() else {
            Issue.record("could not make the test image")
            return
        }
        let pixels = PixelImage(cgImage: cgImage)
        #expect(pixels != nil)
        guard let pixels else { return }
        #expect(pixels.width == 20)
        #expect(pixels.height == 10)
        // CoreGraphics draws with the origin at the bottom left, but a bitmap's
        // memory is top-down: the rect at CG y = 0...5 is the bottom of the
        // image, which is the last rows in memory.
        #expect((pixels.color(x: 10, y: 1)?.luminance ?? 0) > 0.95)
        #expect((pixels.color(x: 10, y: 8)?.luminance ?? 1) < 0.05)
    }

    @Test("the colour components are clamped to 0...1")
    func clampedComponents() {
        let colour = RGBColor(red: 1.5, green: -0.2, blue: 0.5)
        #expect(colour.red == 1)
        #expect(colour.green == 0)
        #expect(colour.blue == 0.5)
    }
}
