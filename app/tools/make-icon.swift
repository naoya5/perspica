// Draws the Yaku app icon's layers as PNGs for Icon Composer (SPEC 6.6).
//
//   swiftc -O tools/make-icon.swift -o /tmp/make-icon
//   /tmp/make-icon Resources/Yaku.icon/Assets
//
// Every layer is 1024×1024 with a transparent background: Icon Composer
// composes them over the background fill and applies the Liquid Glass
// material. The picture is the app's own menu bar symbol, `character.bubble`
// (SPEC 4.1), drawn large: a speech bubble holding 文 (the character that
// stands for text) with a small A, which is what the app does.
//
// The menu bar icon stays an SF Symbol and is *not* this drawing (SPEC 4.1:
// a template image so the system picks the colour). This is the icon in the
// Dock, the app switcher and Finder.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Yaku.icon/Assets"
let side = 1024

func makeContext() -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func write(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDirectory).appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else {
        FileHandle.standardError.write(Data("could not open \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
    print("wrote \(url.path)")
}

func colour(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

/// The bubble outline, in a 1024 box with a margin so the glass edge is not
/// clipped. The tail points down to the left, which is where the text comes
/// from.
func bubblePath() -> CGPath {
    let path = CGMutablePath()
    let rect = CGRect(x: 118, y: 232, width: 788, height: 600)
    let radius: CGFloat = 150
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    path.move(to: CGPoint(x: 300, y: 244))
    path.addLine(to: CGPoint(x: 236, y: 92))
    path.addLine(to: CGPoint(x: 470, y: 240))
    path.closeSubpath()
    return path
}

// MARK: layer 1: the glass bubble

func drawBubble() -> CGImage {
    let context = makeContext()
    let path = bubblePath()

    // A vertical gradient so the glass has a direction, plus a light edge at
    // the top and a darker one at the bottom, which is what the material
    // reads as a lit surface.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [colour(1.0, 1.0, 1.0, 0.98), colour(0.86, 0.92, 1.0, 0.86)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 832),
        end: CGPoint(x: 512, y: 92),
        options: []
    )
    context.restoreGState()

    context.addPath(path)
    context.setStrokeColor(colour(1, 1, 1, 0.85))
    context.setLineWidth(14)
    context.strokePath()

    return context.makeImage()!
}

// MARK: layer 2: 文 and A

func drawGlyphs() -> CGImage {
    let context = makeContext()
    let ink = colour(0.08, 0.13, 0.28)

    // 文, large, on the left of the bubble. Drawn as text rather than as
    // paths so the shape matches what the app translates.
    let ideograph = "文" as NSString
    let big = NSFont.systemFont(ofSize: 420, weight: .semibold)
    let bigAttributes: [NSAttributedString.Key: Any] = [
        .font: big,
        .foregroundColor: NSColor(cgColor: ink)!,
    ]
    let bigSize = ideograph.size(withAttributes: bigAttributes)
    let bigOrigin = CGPoint(x: 430 - bigSize.width / 2, y: 532 - bigSize.height / 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    ideograph.draw(at: bigOrigin, withAttributes: bigAttributes)

    // A, smaller, to the right and lower, so the bubble reads as "text, in
    // two languages" at a glance.
    let latin = "A" as NSString
    let small = NSFont.systemFont(ofSize: 230, weight: .bold)
    let smallAttributes: [NSAttributedString.Key: Any] = [
        .font: small,
        .foregroundColor: NSColor(cgColor: colour(0.13, 0.36, 0.78))!,
    ]
    let smallSize = latin.size(withAttributes: smallAttributes)
    let smallOrigin = CGPoint(x: 726 - smallSize.width / 2, y: 402 - smallSize.height / 2)
    latin.draw(at: smallOrigin, withAttributes: smallAttributes)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()!
}

try? FileManager.default.createDirectory(
    atPath: outDirectory,
    withIntermediateDirectories: true
)
write(drawBubble(), "bubble.png")
write(drawGlyphs(), "glyphs.png")
