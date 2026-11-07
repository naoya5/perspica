import CoreGraphics
import Observation
import YakuCore

/// One recognised block, placed on the overlay and painted (SPEC 4.6 の 3).
struct OverlayBlock: Identifiable {
    /// The block's index in reading order, top to bottom.
    let id: Int
    /// The text as read from the screen.
    let source: String
    /// Where the block sits in the overlay window, AppKit coordinates (origin
    /// at the window's bottom left).
    let frame: CGRect
    /// One original line's height in the window's points (the block is
    /// several lines tall, so its frame cannot stand in for this).
    let lineHeight: CGFloat
    /// The colour the original text sat on, taken from a ring around the block.
    let background: RGBColor
    /// The colour the original text was written in.
    let textColor: RGBColor
    /// True when the original text was heavy, so the translation keeps that
    /// weight (SPEC 4.6 の 3).
    let isBold: Bool
    /// Filled in when the translation arrives.
    var translation: String?
    /// How the translation was sized to the block, decided with the translation.
    var layout: OverlayTextLayout?

    /// The colour the backing is painted with, as a SwiftUI `Color`.
    var hasTranslation: Bool { !(translation ?? "").isEmpty }
}

/// What the overlay is doing, and what it is drawing.
@MainActor
@Observable
final class OverlayModel {
    enum Phase: Equatable {
        case idle
        case picking
        case reading
        case showing
        /// The screen had no readable text (SPEC 13).
        case empty
        /// The screen recording permission is missing (SPEC 13).
        case needsPermission
        case failed(String)
    }

    var phase: Phase = .idle
    var blocks: [OverlayBlock] = []
    /// Where the window claims clicks: the blocks and the bottom band.
    var hitRects: [CGRect] = []
    /// True while ⌥ is held, so the source shows instead of the translation.
    var optionDown = false
    /// Toggled by the band's 「原文を表示」 item.
    var showSource = false
    /// The window's size in points, so a block's SwiftUI offset can be worked
    /// out from its AppKit rect.
    var windowHeight: CGFloat = 0
    var windowWidth: CGFloat = 0
    /// The small 「コピーしました」 note.
    var toast: String?
    /// Demo only (`--demo-image`): the picture the blocks were read from, drawn
    /// in the window so a screenshot shows the translations over the text they
    /// cover. The real path leaves this nil and the screen shows through.
    var backdrop: CGImage?
    /// The scale the demo backdrop is drawn at (SPEC 15 の `--demo-scale`).
    var backdropScale: CGFloat = 1

    /// The band sits in the same place the controller reports to the window.
    static let bandSize = CGSize(width: 400, height: 44)
    static let bandInset: CGFloat = 24

    static func bandRect(windowSize: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - bandSize.width) / 2,
            y: bandInset,
            width: bandSize.width,
            height: bandSize.height
        )
    }

    /// How many blocks have a translation yet, for the log.
    var translatedCount: Int { blocks.filter(\.hasTranslation).count }

    func reset() {
        blocks = []
        hitRects = []
        toast = nil
        showSource = false
        backdrop = nil
        backdropScale = 1
    }
}
