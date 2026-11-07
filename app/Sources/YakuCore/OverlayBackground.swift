import CoreGraphics
import Foundation

/// A colour without any AppKit dependency, so `YakuCore` stays UI-free. The
/// overlay's view turns it into a SwiftUI `Color`.
public struct RGBColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 1, green: 1, blue: 1)

    /// Relative luminance (sRGB coefficients), 0 for black and 1 for white.
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public var isLight: Bool { luminance >= 0.5 }

    /// How far apart two colours are in luminance, 0...1.
    public func contrast(with other: RGBColor) -> Double {
        abs(luminance - other.luminance)
    }
}

/// A plain RGBA8 image, row-major with the origin at the top left. Only what
/// the overlay needs to read colours out of a screenshot (SPEC 4.6 の 3).
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    /// Four bytes per pixel, in R, G, B, A order.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Redraws a `CGImage` into a known RGBA8 layout, so the pixel order does
    /// not depend on whatever the capture happened to hand back.
    public init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: buffer)
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public func color(x: Int, y: Int) -> RGBColor? {
        guard contains(x: x, y: y) else { return nil }
        let offset = (y * width + x) * 4
        return RGBColor(
            red: Double(pixels[offset]) / 255,
            green: Double(pixels[offset + 1]) / 255,
            blue: Double(pixels[offset + 2]) / 255
        )
    }

    /// One pixel's luminance, 0 for black and 1 for white (0 outside the
    /// picture). The ink rules read the picture through this.
    public func luminance(x: Int, y: Int) -> Double {
        guard let color = color(x: x, y: y) else { return 0 }
        return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }
}

/// Reads the colours the overlay paints a block with (SPEC 4.6 の 3): the
/// background from the ring just outside the block, and the text colour from
/// the ink inside it.
public enum OverlayBackground {
    /// How far outside the block the background is sampled.
    public static let ringWidth: CGFloat = 3
    /// At most this many pixels are sampled, so a large block stays cheap.
    public static let maximumSamples = 4000
    /// A pixel counts as ink when its luminance differs from the background by
    /// more than this.
    public static let minimumInkContrast = 0.25
    /// The text colour is only kept when it is at least this readable against
    /// the background; otherwise black or white is used.
    public static let minimumReadableContrast = 0.3

    /// The dominant colour in a ring just outside `rect` (the median of each
    /// channel, which ignores a stray dark pixel or two).
    public static func color(in image: PixelImage, around rect: CGRect) -> RGBColor {
        let outer = rect.insetBy(dx: -ringWidth, dy: -ringWidth)
        var samples: [RGBColor] = []
        samples.reserveCapacity(512)

        let step = stride(for: outer)
        var y = Int(outer.minY.rounded(.down))
        while y <= Int(outer.maxY.rounded(.up)) {
            var x = Int(outer.minX.rounded(.down))
            while x <= Int(outer.maxX.rounded(.up)) {
                defer { x += step }
                // The ring only: anything inside the block is the text itself.
                if rect.contains(CGPoint(x: Double(x), y: Double(y))) { continue }
                guard let color = image.color(x: x, y: y) else { continue }
                samples.append(color)
            }
            y += step
        }

        guard !samples.isEmpty else { return fallback(in: image, rect: rect) }
        return median(samples)
    }

    /// The colour of the text inside a block. Falls back to black or white when
    /// the image gives no clear answer (SPEC 4.6 の 3).
    public static func textColor(in image: PixelImage, block rect: CGRect, background: RGBColor) -> RGBColor {
        var ink: [RGBColor] = []
        var samples = 0

        let step = stride(for: rect)
        var y = Int(rect.minY.rounded(.down))
        while y <= Int(rect.maxY.rounded(.up)) {
            var x = Int(rect.minX.rounded(.down))
            while x <= Int(rect.maxX.rounded(.up)) {
                defer { x += step }
                guard samples < maximumSamples else { break }
                guard let color = image.color(x: x, y: y) else { continue }
                samples += 1
                if color.contrast(with: background) > minimumInkContrast {
                    ink.append(color)
                }
            }
            y += step
        }

        guard !ink.isEmpty else { return contrasting(against: background) }
        let mean = mean(ink)
        guard mean.contrast(with: background) >= minimumReadableContrast else {
            return contrasting(against: background)
        }
        return mean
    }

    /// Black on a light background, white on a dark one.
    public static func contrasting(against background: RGBColor) -> RGBColor {
        background.isLight ? .black : .white
    }

    // MARK: helpers

    private static func stride(for rect: CGRect) -> Int {
        let pixels = Int(max(rect.width, 1)) * Int(max(rect.height, 1))
        guard pixels > maximumSamples else { return 1 }
        return max(1, Int((Double(pixels) / Double(maximumSamples)).squareRoot().rounded(.up)))
    }

    private static func median(_ samples: [RGBColor]) -> RGBColor {
        func middle(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return RGBColor(
            red: middle(samples.map(\.red)),
            green: middle(samples.map(\.green)),
            blue: middle(samples.map(\.blue))
        )
    }

    private static func mean(_ samples: [RGBColor]) -> RGBColor {
        let count = Double(samples.count)
        return RGBColor(
            red: samples.reduce(0) { $0 + $1.red } / count,
            green: samples.reduce(0) { $0 + $1.green } / count,
            blue: samples.reduce(0) { $0 + $1.blue } / count
        )
    }

    /// Used when the block covers the whole image and there is no ring to read.
    private static func fallback(in image: PixelImage, rect: CGRect) -> RGBColor {
        var samples: [RGBColor] = []
        let step = stride(for: rect)
        var y = Int(rect.minY.rounded(.down))
        while y <= Int(rect.maxY.rounded(.up)) {
            var x = Int(rect.minX.rounded(.down))
            while x <= Int(rect.maxX.rounded(.up)) {
                defer { x += step }
                guard samples.count < maximumSamples else { break }
                if let color = image.color(x: x, y: y) { samples.append(color) }
            }
            y += step
        }
        return samples.isEmpty ? .white : median(samples)
    }
}
