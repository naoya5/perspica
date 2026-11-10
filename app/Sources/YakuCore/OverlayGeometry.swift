import Foundation

/// Shared geometry for the backing and the AppKit event mask.
public enum OverlayGeometry {
    public static func wideningWidth(frame: CGRect, neighbors: [CGRect], captureRight: CGFloat, gap: CGFloat = 8) -> CGFloat? {
        var boundary = captureRight
        for other in neighbors where other.minX >= frame.maxX - 1
            && other.maxY > frame.minY && other.minY < frame.maxY {
            boundary = min(boundary, other.minX - gap)
        }
        let width = boundary - frame.minX
        return width > frame.width ? width : nil
    }

    /// Text stays anchored at the original top and grows down, not away from it.
    public static func hitRect(frame: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - max(frame.height, height),
               width: max(frame.width, width), height: max(frame.height, height))
            .insetBy(dx: -4, dy: -2)
    }
}
