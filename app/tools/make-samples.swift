// Draws the M4 sample images with CoreText: an English article, a two-column
// page, a dark UI screen, and a paragraph that mixes Japanese and English lines
// (M5.2). Written to $TMPDIR/yaku-m4/.
//
//   swift make-samples.swift <output folder>
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let width: CGFloat = 1440
let height: CGFloat = 900

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yaku-m4")

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Draw in top-left coordinates, the way the overlay's rects are expressed.
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    return context
}

func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor) {
    context.setFillColor(color)
    context.fill(rect)
}

/// Draws an attributed string inside `rect`, returning the height it used.
@discardableResult
func drawText(_ context: CGContext, _ text: NSAttributedString, in rect: CGRect) -> CGFloat {
    let path = CGPath(rect: rect, transform: nil)
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    context.saveGState()
    // CoreText draws bottom-up in this flipped context, so flip it back.
    context.translateBy(x: 0, y: rect.maxY + rect.minY)
    context.scaleBy(x: 1, y: -1)
    CTFrameDraw(frame, context)
    context.restoreGState()
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: 0, length: 0),
        nil,
        CGSize(width: rect.width, height: .greatestFiniteMagnitude),
        nil
    )
    return size.height
}

func attributed(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false, lineSpacing: CGFloat = 6) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.lineBreakMode = .byWordWrapping
    let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    return NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
    ])
}

func write(_ context: CGContext, _ name: String) {
    guard let image = context.makeImage() else { fatalError("no image") }
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("no destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.path) (\(image.width)x\(image.height))")
}

let white = NSColor.white
let nearBlack = NSColor(calibratedWhite: 0.09, alpha: 1)
let grayText = NSColor(calibratedWhite: 0.35, alpha: 1)

// MARK: 1. an English article, one screen

func article() {
    let context = makeContext()
    fill(context, CGRect(x: 0, y: 0, width: width, height: height), white.cgColor)
    // A page frame and a running head, like a browser window's content.
    fill(context, CGRect(x: 0, y: 0, width: width, height: 56), NSColor(calibratedWhite: 0.95, alpha: 1).cgColor)
    drawText(context, attributed("The Attention Mechanism", size: 13, color: grayText),
             in: CGRect(x: 48, y: 18, width: 600, height: 24))

    let body = """
    The dominant sequence transduction models are based on complex recurrent or convolutional \
    neural networks that include an encoder and a decoder. The best performing models also connect \
    the encoder and decoder through an attention mechanism. We propose a new simple network \
    architecture, the Transformer, based solely on attention mechanisms, dispensing with recurrence \
    and convolutions entirely.

    Experiments on two machine translation tasks show these models to be superior in quality while \
    being more parallelizable and requiring significantly less time to train. Our model achieves \
    28.4 BLEU on the WMT 2014 English-to-German translation task, improving over the existing best \
    results, including ensembles, by over 2 BLEU.

    Recurrent models typically factor computation along the symbol positions of the input and output \
    sequences. This inherently sequential nature precludes parallelization within training examples, \
    which becomes a critical bottleneck at longer sequence lengths. Attention mechanisms allow \
    modeling of dependencies without regard to their distance in the input or output sequences.
    """
    drawText(context, attributed("Attention Is All You Need", size: 40, color: nearBlack, bold: true, lineSpacing: 2),
             in: CGRect(x: 96, y: 110, width: width - 192, height: 70))
    drawText(context, attributed(body, size: 19, color: nearBlack, lineSpacing: 9),
             in: CGRect(x: 96, y: 200, width: width - 192, height: height - 260))
    write(context, "article.png")
}

// MARK: 2. a two-column page

func columns() {
    let context = makeContext()
    fill(context, CGRect(x: 0, y: 0, width: width, height: height), white.cgColor)
    drawText(context, attributed("Findings", size: 34, color: nearBlack, bold: true, lineSpacing: 2),
             in: CGRect(x: 72, y: 60, width: width - 144, height: 50))

    let left = """
    The encoder is composed of a stack of six identical layers. Each layer has two sub-layers. \
    The first is a multi-head self-attention mechanism, and the second is a simple, position-wise \
    fully connected feed-forward network. We employ a residual connection around each of the two \
    sub-layers, followed by layer normalization.

    That is, the output of each sub-layer is LayerNorm(x + Sublayer(x)), where Sublayer(x) is the \
    function implemented by the sub-layer itself. To facilitate these residual connections, all \
    sub-layers in the model, as well as the embedding layers, produce outputs of dimension 512.
    """
    let right = """
    The decoder is also composed of a stack of six identical layers. In addition to the two \
    sub-layers in each encoder layer, the decoder inserts a third sub-layer, which performs \
    multi-head attention over the output of the encoder stack.

    We also modify the self-attention sub-layer in the decoder stack to prevent positions from \
    attending to subsequent positions. This masking, combined with the fact that the output \
    embeddings are offset by one position, ensures that the predictions for position i can depend \
    only on the known outputs at positions less than i.
    """
    drawText(context, attributed(left, size: 17, color: nearBlack, lineSpacing: 8),
             in: CGRect(x: 72, y: 140, width: 620, height: height - 200))
    drawText(context, attributed(right, size: 17, color: nearBlack, lineSpacing: 8),
             in: CGRect(x: 748, y: 140, width: 620, height: height - 200))
    write(context, "columns.png")
}

// MARK: 3. a dark UI screen

func ui() {
    let context = makeContext()
    let background = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor
    let panel = NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.19, alpha: 1).cgColor
    let line = NSColor(calibratedRed: 0.25, green: 0.27, blue: 0.31, alpha: 1).cgColor
    let ink = NSColor(calibratedWhite: 0.93, alpha: 1)
    let muted = NSColor(calibratedWhite: 0.62, alpha: 1)

    fill(context, CGRect(x: 0, y: 0, width: width, height: height), background)
    // Sidebar.
    fill(context, CGRect(x: 0, y: 0, width: 300, height: height), panel)
    fill(context, CGRect(x: 300, y: 0, width: 1, height: height), line)
    // Toolbar.
    fill(context, CGRect(x: 301, y: 0, width: width - 301, height: 64), panel)
    fill(context, CGRect(x: 301, y: 64, width: width - 301, height: 1), line)

    drawText(context, attributed("Settings", size: 15, color: ink, bold: true),
             in: CGRect(x: 24, y: 24, width: 240, height: 24))
    for (index, item) in ["General", "Appearance", "Notifications", "Privacy"].enumerated() {
        let y = 80 + CGFloat(index) * 34
        drawText(context, attributed(item, size: 14, color: index == 0 ? ink : muted),
                 in: CGRect(x: 40, y: y, width: 240, height: 24))
    }
    drawText(context, attributed("Notifications", size: 20, color: ink, bold: true),
             in: CGRect(x: 340, y: 22, width: 400, height: 30))

    let rows: [(String, String)] = [
        ("Enable notifications", "Show a banner when a job finishes"),
        ("Play a sound", "Use the system alert sound"),
        ("Show in Lock Screen", "Keep recent items visible"),
        ("Group by app", "Collect alerts from one app together"),
    ]
    for (index, row) in rows.enumerated() {
        let y = 110 + CGFloat(index) * 88
        fill(context, CGRect(x: 340, y: y, width: width - 420, height: 1), line)
        drawText(context, attributed(row.0, size: 15, color: ink),
                 in: CGRect(x: 340, y: y + 18, width: 520, height: 24))
        drawText(context, attributed(row.1, size: 12, color: muted),
                 in: CGRect(x: 340, y: y + 42, width: 620, height: 20))
        // A switch.
        let switchRect = CGRect(x: width - 160, y: y + 24, width: 52, height: 30)
        fill(context, switchRect, (index < 2 ? NSColor.systemBlue : NSColor(calibratedWhite: 0.35, alpha: 1)).cgColor)
        fill(context, CGRect(x: switchRect.minX + (index < 2 ? 24 : 3), y: switchRect.minY + 3,
                             width: 24, height: 24),
             NSColor.white.cgColor)
    }
    write(context, "ui.png")
}

// MARK: 4. a paragraph that mixes Japanese and English lines

/// One paragraph whose lines mix the two scripts, so the size rule (M5.md 9.2)
/// can be checked against the worst case it could break: a Japanese line and an
/// English line of the same 17 points, in one paragraph. The heading is there
/// so the sample also has a line of a clearly different size.
///
/// The three lines are broken by hand rather than by wrapping, so each is long
/// enough (0.7 of the line below it, M5.md 8.1) that the line-length rule
/// leaves the paragraph whole and only the size rule can split it.
func mixed() {
    let context = makeContext()
    fill(context, CGRect(x: 0, y: 0, width: width, height: height), white.cgColor)
    drawText(context, attributed("混ざった段落", size: 34, color: nearBlack, bold: true, lineSpacing: 2),
             in: CGRect(x: 72, y: 60, width: width - 144, height: 50))

    // Japanese, English, Japanese, all at 17 points. The ink band reads the
    // English line 29% smaller than the Japanese one above it, which would
    // split them; the width of the ink reads them within 2% (M5.md 9.2).
    let body = """
        エンコーダは、同一の層が 6 層積層された構成となっている。各層には 2 つのサブレイヤが存在し、1 つ目は multi-head self-attention 機構である。
        We employ a residual connection around each of the two sub-layers, followed by layer normalization, and the same holds for every other sub-layer.
        これら 2 つのサブレイヤのそれぞれに残差接続を採用し、続いてレイヤ正規化を行う。
        """
    drawText(context, attributed(body, size: 17, color: nearBlack, lineSpacing: 8),
             in: CGRect(x: 72, y: 140, width: width - 144, height: 180))

    let second = "デコーダもまた、同一の層が 6 層積層された構成となっている。エンコーダ層の 2 つのサブレイヤに加え、デコーダは第 3 のサブレイヤを挿入しており、これがエンコーダ積層の出力に対して multi-head attention を実行する。"
    drawText(context, attributed(second, size: 17, color: nearBlack, lineSpacing: 8),
             in: CGRect(x: 72, y: 400, width: width - 144, height: 240))
    write(context, "mixed.png")
}

article()
columns()
ui()
mixed()
