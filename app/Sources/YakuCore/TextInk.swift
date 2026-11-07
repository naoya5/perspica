import CoreGraphics
import Foundation

/// Measures how large the text in a line was, from the picture's own ink
/// (SPEC 4.6 の 3).
///
/// The size cannot be taken from Vision's line box. The box is the ink's
/// extent plus the detector's own padding, and the padding moves with the
/// picture it was given. On the UI sample, `Use the system alert sound` came
/// back 14.7 pixels tall from the whole-picture pass and 12.0 from a tile, and
/// the four 14-point sidebar labels came back in 12.0- to 14.3-pixel boxes. The
/// overlay drew those four at 8.3 to 11.7 points, one of them at the 0.70
/// floor, where the picture has one size (M5.md 8.2).
///
/// The ink band does not have that problem, because it is read from the pixels:
/// the pass that found the line cannot change it. The band is the run of rows
/// whose ink covers at least half of the busiest row's, which for a line of
/// text is its x-height plus the antialiased edges, so the size follows from it
/// as `size = (band - bandOffset) / xHeightRatio`. Both constants were fitted
/// to the three samples' 38 lines, drawn at 1× and again at 2× (eight sizes
/// from 12 to 40 points, M5.md 8.2): the fit lands within 3% of the true size
/// at 2× and 9% at 1×, and, which is what the overlay needs, lines of the same
/// size come out within 0.2–2.1% of each other where Vision's box spread them
/// over 19%.
///
/// Two limits are worth knowing. Small **bold** text reads up to 15% large (the
/// thicker strokes fill more of the ascender and descender rows), and a line of
/// capitals reads large for the same reason. Neither shows up on the samples'
/// headings, which the fit gets within 2%. A CJK line also reads a little large
/// against a Latin one of the same size (measured: 14.7 against 14.5 on the UI
/// sample, where the source draws both at 14 and 15), because the band is
/// normalised by the busiest row and CJK fills more of its box.
public enum TextInk {
    /// The share of the busiest row's ink a row needs to count as part of the
    /// band.
    public static let bandLevel: Double = 0.5
    /// The band is this share of the drawn size (the x-height of the system
    /// font), fitted.
    public static let xHeightRatio: Double = 0.5311
    /// What the antialiased edges add to the band, in image pixels, fitted.
    public static let bandOffset: Double = 0.137
    /// A pixel counts as ink when its luminance differs from the line's
    /// background by more than this (the same rule the text colour uses).
    public static let inkContrast: Double = 0.24
    /// Below this many pixels the band is too small to read a size out of.
    public static let minimumBand: CGFloat = 4

    /// The height of one line's ink band, in image pixels, or nil when the line
    /// holds nothing to measure.
    ///
    /// The band is the run of rows whose ink covers at least `bandLevel` of the
    /// busiest row's, with the two edges interpolated so the answer is not
    /// rounded to whole rows (at a 12-point size one row is 8% of the size).
    public static func bandHeight(in image: PixelImage, line rect: CGRect) -> CGFloat? {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let x1 = min(image.width - 1, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let y1 = min(image.height - 1, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }

        // The line's background is the median luminance of its box; the ink is
        // whatever sits on the far side of it.
        var luminances: [Double] = []
        luminances.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1) / 4)
        for y in stride(from: y0, through: y1, by: 2) {
            for x in stride(from: x0, through: x1, by: 2) {
                luminances.append(image.luminance(x: x, y: y))
            }
        }
        guard !luminances.isEmpty else { return nil }
        let sorted = luminances.sorted()
        let background = sorted[sorted.count / 2]
        let darkText = background > 0.5
        let threshold = background + (darkText ? -inkContrast : inkContrast)

        // Every column is counted, so the answer depends on the text and not on
        // where the box was cut: sampling every other column was within 0.2
        // points of this, but which columns a box skips moves with the box, and
        // the whole point of the band is to be the same from any crop.
        var profile: [Double] = []
        profile.reserveCapacity(y1 - y0 + 1)
        let columns = x1 - x0 + 1
        for y in y0...y1 {
            var ink = 0
            for x in x0...x1 {
                let value = image.luminance(x: x, y: y)
                if darkText ? (value < threshold) : (value > threshold) { ink += 1 }
            }
            profile.append(Double(ink) / Double(columns))
        }

        guard let peak = profile.max(), peak > 0 else { return nil }
        let level = peak * bandLevel
        guard let first = profile.firstIndex(where: { $0 >= level }),
              let last = profile.lastIndex(where: { $0 >= level }),
              last >= first
        else { return nil }

        let top = first > 0 ? crossing(from: first - 1, to: first, level: level, profile: profile) : CGFloat(first)
        let bottom = last + 1 < profile.count
            ? crossing(from: last, to: last + 1, level: level, profile: profile)
            : CGFloat(last)
        return bottom - top
    }

    /// Where the profile crosses `level` between two rows.
    private static func crossing(from: Int, to: Int, level: Double, profile: [Double]) -> CGFloat {
        let a = profile[from]
        let b = profile[to]
        guard a != b else { return CGFloat(from) }
        return CGFloat(from) + CGFloat((level - a) / (b - a))
    }

    /// The size the band was drawn at, in the caller's points, or nil when the
    /// band is too small to measure.
    public static func fontSize(forBand band: CGFloat, pointsPerPixel: CGFloat = 1) -> CGFloat? {
        guard band >= minimumBand else { return nil }
        let size = (band - bandOffset) / xHeightRatio
        guard size > 0 else { return nil }
        return size * pointsPerPixel
    }

    /// One line's size in the caller's points.
    public static func fontSize(in image: PixelImage, line rect: CGRect, pointsPerPixel: CGFloat = 1) -> CGFloat? {
        guard let band = bandHeight(in: image, line: rect) else { return nil }
        return fontSize(forBand: band, pointsPerPixel: pointsPerPixel)
    }
}
