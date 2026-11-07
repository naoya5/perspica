import AppKit

/// Geometry for the panel window and the glass shape inside it.
///
/// The window is larger than the shape so the shape's own shadow and the
/// processing light have room to fade out. It is only ever as tall as the
/// tallest state, and it never reaches into the menu bar, so clicks on menu bar
/// items keep working.
enum PanelLayout {
    static let width: CGFloat = 400
    static let minHeight: CGFloat = 168
    static let maxHeight: CGFloat = 600
    static let shadowMargin: CGFloat = 32
    static let cornerRadius: CGFloat = 24
    /// Distance between the menu bar's bottom edge and the top of the panel.
    static let gapBelowMenuBar: CGFloat = 6
    /// The panel never comes closer than this to a screen edge.
    static let screenEdgeInset: CGFloat = 8
    /// SPEC 6.4: the panel's inner padding.
    static let innerPadding: CGFloat = 16

    // The three bands' heights (SPEC 4.2).
    static let topBarHeight: CGFloat = 36
    static let bottomBarHeight: CGFloat = 32
    static let quickBarHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 1

    // Text sizes and the line spacing that goes with them.
    static let sourceFontSize: CGFloat = 14
    static let sourceLineSpacing: CGFloat = 4
    static let translationFontSize: CGFloat = 15
    /// SPEC 4.2: 行間 1.45 倍.
    static let translationLineSpacing: CGFloat = 15 * 0.45
    /// Height of one line of the source field, including its own padding.
    static let sourceLineHeight: CGFloat = 21
    /// The empty state's source field: about two lines, so the panel does not
    /// look like a blank face (M0's note).
    static let emptySourceHeight: CGFloat = 56
    /// Height of the 「準備しています…」 / error area at its smallest.
    static let minimumTranslationHeight: CGFloat = 34
    /// Height of the translation area while a translation streams (SPEC 14, M5:
    /// the panel keeps one height so it is not re-laid out for every piece).
    static let workingTranslationHeight: CGFloat = 240
    /// The 「作業中の PDF」 row (SPEC 4.2 の 6).
    static let pdfRowHeight: CGFloat = 48
    /// The drop state: the well replaces the whole content (SPEC 4.2).
    static let dropHeight: CGFloat = 180

    static var windowWidth: CGFloat { width + shadowMargin * 2 }
    static var windowHeight: CGFloat { maxHeight + shadowMargin }
    static var windowSize: CGSize { CGSize(width: windowWidth, height: windowHeight) }
    static var contentWidth: CGFloat { width - innerPadding * 2 }

    /// The shape sits at the top of the window, horizontally centred.
    static func shapeRect(in bounds: CGRect, height: CGFloat, flipped: Bool) -> CGRect {
        let y: CGFloat = flipped ? 0 : bounds.height - height
        return CGRect(x: shadowMargin, y: y, width: width, height: height)
    }
}

/// Geometry for the selection HUD (SPEC 4.3).
enum HUDLayout {
    static let width: CGFloat = 420
    static let maxHeight: CGFloat = 360
    static let shadowMargin: CGFloat = 24
    static let cornerRadius: CGFloat = 18
    static let innerPadding: CGFloat = 14
    static let footerHeight: CGFloat = 26
    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 14 * 0.45
    static let minimumTextHeight: CGFloat = 20
    /// Distance between the selection and the HUD.
    static let gap: CGFloat = 8
    static let screenEdgeInset: CGFloat = 8

    static var windowWidth: CGFloat { width + shadowMargin * 2 }
    static var windowHeight: CGFloat { maxHeight + shadowMargin }
    static var windowSize: CGSize { CGSize(width: windowWidth, height: windowHeight) }
    static var contentWidth: CGFloat { width - innerPadding * 2 }

    static func shapeRect(in bounds: CGRect, height: CGFloat, flipped: Bool) -> CGRect {
        let y: CGFloat = flipped ? 0 : bounds.height - height
        return CGRect(x: shadowMargin, y: y, width: width, height: height)
    }
}
