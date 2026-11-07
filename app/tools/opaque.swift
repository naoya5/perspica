// Prints how many pixels of a PNG are not transparent (sampled every other
// pixel), so the capture scripts can drop the empty windows AppKit keeps
// onscreen (the hidden panel, the closed island) and keep the real surface.
//
//   swiftc -O tools/opaque.swift -o /tmp/opaque
//   /tmp/opaque shot.png        # -> 123456
import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count > 1,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print(0)
    exit(1)
}
let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else { print(0); exit(1) }
var count = 0
for y in stride(from: 0, to: height, by: 2) {
    for x in stride(from: 0, to: width, by: 2) where pixels[(y * width + x) * 4 + 3] > 16 {
        count += 1
    }
}
print(count)
