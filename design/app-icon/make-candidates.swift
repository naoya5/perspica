// Draws the app icon candidates as Icon Composer documents (`.icon`).
//
//   swift design/app-icon/make-candidates.swift <fonts folder> design/app-icon
//
// The fonts folder holds these SIL Open Font License files from
// https://github.com/google/fonts/tree/main/ofl: ZenKakuGothicNew-Black.ttf,
// Cinzel[wght].ttf, CinzelDecorative-Black.ttf,
// CormorantGaramond-Italic[wght].ttf, ShipporiMinchoB1-ExtraBold.ttf and
// YujiSyuku-Regular.ttf.
//
// Each candidate is a folder `<Name>.icon` with `icon.json` and one SVG per
// layer under `Assets/`. The layers follow Apple's guidance for Liquid Glass
// icons: 1024 × 1024, square and unmasked, one flat colour each, glyphs as
// outlines, no shadows, blurs, highlights or gradients inside the artwork.
// The background gradient, opacity, translucency and specular highlights are
// set in `icon.json`, so the system can render every appearance.
//
// Check every appearance and size with Icon Composer's renderer:
//   ictool <Name>.icon --export-image --output-file out.png --platform macOS \
//       --rendition Default|Dark|ClearLight|ClearDark|TintedLight|TintedDark \
//       --width 16 --height 16 --scale 1
import CoreGraphics
import CoreText
import Foundation

let side: CGFloat = 1024

// MARK: geometry

func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

func ring(_ cx: CGFloat, _ cy: CGFloat, outer: CGFloat, inner: CGFloat) -> CGPath {
    disc(cx, cy, outer).subtracting(disc(cx, cy, inner))
}

/// A stroke turned into a filled outline, so the layer is one flat shape.
func stroke(_ build: (CGMutablePath) -> Void, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    build(path)
    return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func unite(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1) }
}

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    roundedRect(x, y, w, h, h / 2)
}

// MARK: glyphs

let fontsDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

/// A font file from the fonts folder; `weight` sets the `wght` axis of a
/// variable font.
func loadFont(_ file: String, weight: CGFloat? = nil) -> CTFont {
    let url = fontsDirectory.appendingPathComponent(file)
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          var descriptor = descriptors.first
    else { fatalError("cannot read \(url.path)") }
    if let weight {
        descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, 0x7767_6874 as CFNumber, weight)
    }
    return CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
}

let zenKaku = loadFont("ZenKakuGothicNew-Black.ttf")
// Each script in the faces it grew up in. Latin: Roman inscriptional
// capitals (Cinzel, after the Trajan column), the Renaissance quill italic
// (Cormorant Garamond Italic) and its ornamented capitals (Cinzel
// Decorative). Hiragana: the woodblock-printed Mincho (Shippori Mincho B1)
// and the brush it came from (Yuji Syuku), あ being the cursive of 安.
let cinzel = loadFont("Cinzel[wght].ttf", weight: 700)
let cinzelDecorative = loadFont("CinzelDecorative-Black.ttf")
let cormorantItalic = loadFont("CormorantGaramond-Italic[wght].ttf", weight: 700)
let shipporiMincho = loadFont("ShipporiMinchoB1-ExtraBold.ttf")
let yujiSyuku = loadFont("YujiSyuku-Regular.ttf")

/// The outline of one character, scaled so its ink is `height` tall and
/// centred on (cx, cy) in the icon's y-down coordinates.
func glyph(_ character: Character, font: CTFont = zenKaku, height: CGFloat, cx: CGFloat, cy: CGFloat) -> CGPath {
    let units = Array(String(character).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count),
          let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("no glyph for \(character)") }
    let box = path.boundingBoxOfPath
    let scale = height / box.height
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                      tx: cx - box.midX * scale, ty: cy + box.midY * scale)
    return path.copy(using: &transform)!
}

// MARK: SVG

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint:
            d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func writeLayer(_ path: CGPath, colour: String, to url: URL) throws {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
    <path fill="\(colour)" fill-rule="nonzero" d="\(svgPathData(path))"/></svg>

    """
    try svg.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: icon.json

/// "srgb:r,g,b,a" from a hex colour.
func c(_ hex: UInt32, _ alpha: Double = 1) -> String {
    let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
    return String(format: "srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> [String: Any] {
    ["linear-gradient": [c(top), c(bottom)],
     "orientation": ["start": ["x": 0.5, "y": 0.0], "stop": ["x": 0.5, "y": 1.0]]]
}

struct Layer {
    var name: String
    var path: CGPath
    var colour: UInt32
    var darkColour: UInt32?
    var opacity: Double = 1
    var glass = true
    /// The colour in the clear and tinted appearances (`"appearance":
    /// "tinted"` covers both), for dark ink that would otherwise turn the
    /// same grey as the glass under it.
    var monoColour: UInt32? = nil
}

struct Group {
    var layers: [Layer]          // front to back
    var translucency: Double?    // nil: off
    var specular = true
    var shadowOpacity = 0.5
    var lighting = "combined"
    var blur: Double?
}

struct Candidate {
    var name: String
    var background: (UInt32, UInt32)
    var darkBackground: (UInt32, UInt32)
    var groups: [Group]          // front to back
}

func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

func write(_ candidate: Candidate, into folder: URL) throws {
    let bundle = folder.appendingPathComponent("\(candidate.name).icon")
    let assets = bundle.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    var groups: [[String: Any]] = []
    for group in candidate.groups {
        var layers: [[String: Any]] = []
        for layer in group.layers {
            let file = "\(layer.name).svg"
            try writeLayer(layer.path, colour: hex(layer.colour), to: assets.appendingPathComponent(file))
            var entry: [String: Any] = ["image-name": file, "name": layer.name, "glass": layer.glass]
            if layer.opacity < 1 { entry["opacity"] = layer.opacity }
            if layer.darkColour != nil || layer.monoColour != nil {
                var specializations: [[String: Any]] = [["value": ["solid": c(layer.colour)]]]
                if let dark = layer.darkColour {
                    specializations.append(["appearance": "dark", "value": ["solid": c(dark)]])
                }
                if let mono = layer.monoColour {
                    specializations.append(["appearance": "tinted", "value": ["solid": c(mono)]])
                }
                entry["fill-specializations"] = specializations
            }
            layers.append(entry)
        }
        var g: [String: Any] = [
            "layers": layers,
            "specular": group.specular,
            "shadow": ["kind": "neutral", "opacity": group.shadowOpacity],
            "lighting": group.lighting,
        ]
        if let t = group.translucency { g["translucency"] = ["enabled": true, "value": t] }
        if let b = group.blur { g["blur-material"] = b }
        groups.append(g)
    }
    let json: [String: Any] = [
        "fill-specializations": [
            ["value": gradient(candidate.background.0, candidate.background.1)],
            ["appearance": "dark", "value": gradient(candidate.darkBackground.0, candidate.darkBackground.1)],
        ],
        "groups": groups,
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: bundle.appendingPathComponent("icon.json"))
    print("wrote \(bundle.path)")
}

// MARK: Perspica · Spectacles

/// Round spectacles. The left lens holds A, the right あ: put them on and the
/// foreign word reads as Japanese.
func perspicaSpectacles() -> Candidate {
    let left: CGFloat = 318, right: CGFloat = 706, cy: CGFloat = 548
    let outer: CGFloat = 176, inner: CGFloat = 126, mid = (outer + inner) / 2
    func point(_ cx: CGFloat, _ degrees: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
    let bridge = stroke({ p in
        p.move(to: point(left, -34, mid))
        p.addQuadCurve(to: point(right, 214, mid), control: CGPoint(x: 512, y: cy - 158))
    }, width: 44)
    let temples = stroke({ p in
        p.move(to: point(left, 198, mid)); p.addLine(to: CGPoint(x: 112, y: cy - 104))
        p.move(to: point(right, -18, mid)); p.addLine(to: CGPoint(x: 912, y: cy - 104))
    }, width: 44)
    let frame = unite([ring(left, cy, outer: outer, inner: inner),
                       ring(right, cy, outer: outer, inner: inner), bridge, temples])
    // The glyphs sit above the lens glass, so they stay legible in the clear
    // and tinted appearances, where everything under glass turns grey.
    return Candidate(
        name: "Perspica-Spectacles",
        background: (0x34469F, 0x13123A),
        darkBackground: (0x1A2050, 0x06071A),
        groups: [
            Group(layers: [Layer(name: "4 Frame", path: frame, colour: 0xFFFFFF, darkColour: 0xEEF1FB)],
                  translucency: nil, shadowOpacity: 0.5),
            Group(layers: [
                Layer(name: "3 Kana", path: glyph("あ", height: 166, cx: right, cy: cy + 4), colour: 0xFFFFFF),
                Layer(name: "3 Latin", path: glyph("A", height: 154, cx: left, cy: cy + 2), colour: 0xFFFFFF),
            ], translucency: nil, specular: false, shadowOpacity: 0.25, lighting: "individual"),
            Group(layers: [
                Layer(name: "2 Lens Right", path: disc(right, cy, inner + 6), colour: 0xFF6FB1, opacity: 0.88),
                Layer(name: "2 Lens Left", path: disc(left, cy, inner + 6), colour: 0x4F8CFF, opacity: 0.88),
            ], translucency: 0.3, shadowOpacity: 0.2, lighting: "individual"),
        ])
}

// MARK: Perspica · Lens

/// One lens over a large A. Through the lens, the A is あ.
func perspicaLens() -> Candidate {
    let lx: CGFloat = 592, ly: CGFloat = 612, outer: CGFloat = 228, inner: CGFloat = 180
    let latin = glyph("A", height: 590, cx: 404, cy: 452).subtracting(disc(lx, ly, outer))
    return Candidate(
        name: "Perspica-Lens",
        background: (0x4766E6, 0x1D2777),
        darkBackground: (0x1F2A63, 0x080C22),
        groups: [
            Group(layers: [Layer(name: "4 Rim", path: ring(lx, ly, outer: outer, inner: inner),
                                 colour: 0xFFFFFF, darkColour: 0xE6EAFF)],
                  translucency: nil, shadowOpacity: 0.5),
            Group(layers: [Layer(name: "3 Kana", path: glyph("あ", height: 220, cx: lx, cy: ly + 4),
                                 colour: 0x1D2777, darkColour: 0x111842, glass: false)],
                  translucency: nil, specular: false, shadowOpacity: 0),
            Group(layers: [Layer(name: "2 Lens", path: disc(lx, ly, inner + 4), colour: 0xFFE2BF,
                                 darkColour: 0xF7D2A6, opacity: 0.92)],
                  translucency: 0.35, shadowOpacity: 0.35),
            Group(layers: [Layer(name: "1 Latin", path: latin, colour: 0xFFFFFF, darkColour: 0xDDE3FF, opacity: 0.9)],
                  translucency: nil, shadowOpacity: 0.4),
        ])
}

// MARK: Pellucid · Pane

/// A sheet of glass over a page. Outside the glass the lines are faint;
/// through it they read clearly.
func pellucidPane() -> Candidate {
    // The lines run on under the glass, so each one is faint on the page and
    // clear through the glass, side by side.
    let page = roundedRect(166, 218, 548, 566, 68)
    let pane = roundedRect(404, 300, 456, 560, 88)
    let lines = unite([bar(232, 352, 420, 60), bar(232, 472, 330, 60), bar(232, 592, 420, 60)])
    return Candidate(
        name: "Pellucid-Pane",
        background: (0xC2F3EE, 0x3FA9C3),
        darkBackground: (0x0F4655, 0x05181F),
        groups: [
            Group(layers: [Layer(name: "4 Clear Lines", path: lines.intersection(pane),
                                 colour: 0x0A4C63, darkColour: 0xF2FDFF, glass: false)],
                  translucency: nil, specular: false, shadowOpacity: 0),
            // A faint aqua tint marks where the glass is, even over the white page.
            Group(layers: [Layer(name: "3 Pane", path: pane, colour: 0x8EE3EA, darkColour: 0x8EE3EA, opacity: 0.42)],
                  translucency: 0.6, shadowOpacity: 0.4),
            Group(layers: [
                Layer(name: "2 Faint Lines", path: lines, colour: 0xA7C6D0, darkColour: 0x6E95A1),
                Layer(name: "1 Page", path: page, colour: 0xFFFFFF, darkColour: 0x2C5866),
            ], translucency: nil, shadowOpacity: 0.4),
        ])
}

// MARK: Pellucid · Drop

/// A drop of water on a page. Under the drop the lines are larger and clear.
func pellucidDrop() -> Candidate {
    let cx: CGFloat = 512, cy: CGFloat = 596, r: CGFloat = 226, apexY: CGFloat = 176
    let d = cy - apexY
    let phi = acos(r / d)
    let tangentLeft = CGPoint(x: cx - r * sin(phi), y: cy - r * cos(phi))
    let tangentRight = CGPoint(x: cx + r * sin(phi), y: cy - r * cos(phi))
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: cx, y: apexY)); cone.addLine(to: tangentRight)
    cone.addLine(to: CGPoint(x: cx, y: cy)); cone.addLine(to: tangentLeft); cone.closeSubpath()
    let sharp = disc(cx, cy, r).union(cone)
    // Round the tip: grow the drop by a round-joined stroke, then keep the size.
    let drop = sharp.union(sharp.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 1))
    let rows: [(CGFloat, CGFloat)] = [(318, 672), (438, 560), (558, 672), (678, 470), (798, 560)]
    let lines = unite(rows.map { bar(176, $0.0, $0.1, 44) })
    // Under the drop: three larger lines, ragged on the right like text and
    // kept whole inside the round part, so the drop's edge stays visible.
    let big = unite([bar(360, 500, 304, 50), bar(346, 580, 270, 50), bar(368, 660, 192, 50)])
    return Candidate(
        name: "Pellucid-Drop",
        background: (0x22A0BA, 0x0A3A4D),
        darkBackground: (0x0B3A48, 0x03141B),
        groups: [
            Group(layers: [Layer(name: "3 Clear Lines", path: big, colour: 0xFFFFFF, glass: false)],
                  translucency: nil, specular: false, shadowOpacity: 0.2),
            Group(layers: [Layer(name: "2 Drop", path: drop, colour: 0xE6FBFF, opacity: 0.34)],
                  translucency: 0.55, shadowOpacity: 0.45),
            Group(layers: [Layer(name: "1 Faint Lines", path: lines, colour: 0xFFFFFF, opacity: 0.4)],
                  translucency: nil, specular: false, shadowOpacity: 0),
        ])
}

// MARK: letter-free candidates (round 2)

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// The polygon pulled in by `gap` on every side, so neighbouring facets are
/// separated by a clean channel rather than touching.
func inset(_ path: CGPath, by gap: CGFloat) -> CGPath {
    path.subtracting(path.copy(strokingWithWidth: gap * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
}

/// Two glass lenses overlapping on the diagonal; where they meet is white.
/// Two languages, one clear understanding.
func perspicaDuo() -> Candidate {
    let a = disc(430, 440, 222), b = disc(594, 604, 222)
    return Candidate(
        name: "Perspica-Duo",
        background: (0x2E3C96, 0x11103A),
        darkBackground: (0x181D48, 0x06071A),
        groups: [
            Group(layers: [Layer(name: "3 Meeting", path: a.intersection(b), colour: 0xFFFFFF)],
                  translucency: nil, shadowOpacity: 0.3),
            Group(layers: [Layer(name: "2 Warm Lens", path: b, colour: 0xFF6FB1, opacity: 0.86)],
                  translucency: 0.35, shadowOpacity: 0.45),
            Group(layers: [Layer(name: "1 Cool Lens", path: a, colour: 0x4F8CFF, opacity: 0.86)],
                  translucency: 0.35, shadowOpacity: 0.45),
        ])
}

/// Round spectacles with nothing written in them: one lens blue, one pink.
func perspicaFrames() -> Candidate {
    let left: CGFloat = 318, right: CGFloat = 706, cy: CGFloat = 540
    let outer: CGFloat = 176, inner: CGFloat = 126, mid = (outer + inner) / 2
    func point(_ cx: CGFloat, _ degrees: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
    let bridge = stroke({ p in
        p.move(to: point(left, -34, mid))
        p.addQuadCurve(to: point(right, 214, mid), control: CGPoint(x: 512, y: cy - 158))
    }, width: 44)
    let temples = stroke({ p in
        p.move(to: point(left, 198, mid)); p.addLine(to: CGPoint(x: 112, y: cy - 104))
        p.move(to: point(right, -18, mid)); p.addLine(to: CGPoint(x: 912, y: cy - 104))
    }, width: 44)
    let frame = unite([ring(left, cy, outer: outer, inner: inner),
                       ring(right, cy, outer: outer, inner: inner), bridge, temples])
    return Candidate(
        name: "Perspica-Frames",
        background: (0xF4F7FC, 0xD2DBEA),
        darkBackground: (0x1A2050, 0x06071A),
        groups: [
            Group(layers: [Layer(name: "2 Frame", path: frame, colour: 0x1C2340, darkColour: 0xF1F3FB)],
                  translucency: nil, shadowOpacity: 0.5),
            Group(layers: [
                Layer(name: "1 Lens Right", path: disc(right, cy, inner + 6), colour: 0xFF6FB1, opacity: 0.8),
                Layer(name: "1 Lens Left", path: disc(left, cy, inner + 6), colour: 0x4F8CFF, opacity: 0.8),
            ], translucency: 0.4, shadowOpacity: 0.25, lighting: "individual"),
        ])
}

/// Grey lines go into a lens and come out in Yaku's colours.
func perspicaPrism() -> Candidate {
    let ys: [CGFloat] = [386, 484, 582]
    let grey = unite(ys.map { bar(124, $0, 410, 56) })
    let colours: [UInt32] = [0x4F8CFF, 0xB36BFF, 0xFF6FB1]
    var lit: [Layer] = []
    for (i, y) in ys.enumerated() {
        lit.append(Layer(name: "2 Light \(i + 1)", path: bar(490, y, 410, 56), colour: colours[i]))
    }
    return Candidate(
        name: "Perspica-Prism",
        background: (0x18254F, 0x070B1C),
        darkBackground: (0x10183A, 0x04060F),
        groups: [
            Group(layers: [Layer(name: "3 Lens", path: disc(512, 512, 214), colour: 0xFFFFFF, opacity: 0.36)],
                  translucency: 0.6, shadowOpacity: 0.45),
            Group(layers: lit, translucency: nil, specular: false, shadowOpacity: 0.2, lighting: "individual"),
            Group(layers: [Layer(name: "1 Grey Lines", path: grey, colour: 0x8EA0C4, opacity: 0.6)],
                  translucency: nil, specular: false, shadowOpacity: 0),
        ])
}

/// Three panes of glass, each clearer than the one behind it.
func pellucidPanes() -> Candidate {
    return Candidate(
        name: "Pellucid-Panes",
        background: (0xC2F3EE, 0x3FA9C3),
        darkBackground: (0x0F4655, 0x05181F),
        groups: [
            Group(layers: [Layer(name: "3 Front", path: roundedRect(368, 368, 420, 420, 104), colour: 0xFFFFFF, opacity: 0.4)],
                  translucency: 0.65, shadowOpacity: 0.45),
            Group(layers: [Layer(name: "2 Middle", path: roundedRect(302, 302, 420, 420, 104), colour: 0x7FE0E8, opacity: 0.7)],
                  translucency: 0.45, shadowOpacity: 0.45),
            Group(layers: [Layer(name: "1 Back", path: roundedRect(236, 236, 420, 420, 104), colour: 0x0B5A70, darkColour: 0x1C8AA3)],
                  translucency: nil, shadowOpacity: 0.45),
        ])
}

/// A clear crystal: crown and pavilion facets, each a separate pane of glass.
func pellucidCrystal() -> Candidate {
    let dy: CGFloat = -40
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
    let a = p(382, 300), b = p(642, 300), l = p(232, 470), r = p(792, 470)
    let m1 = p(412, 470), m2 = p(612, 470), tip = p(512, 800)
    let gap: CGFloat = 9
    let crownLeft = inset(polygon([l, a, m1]), by: gap)
    let table = inset(polygon([a, b, m2, m1]), by: gap)
    let crownRight = inset(polygon([b, r, m2]), by: gap)
    let pavilionLeft = inset(polygon([l, m1, tip]), by: gap)
    let pavilionMiddle = inset(polygon([m1, m2, tip]), by: gap)
    let pavilionRight = inset(polygon([m2, r, tip]), by: gap)
    return Candidate(
        name: "Pellucid-Crystal",
        background: (0x2A7FD0, 0x0B2457),
        darkBackground: (0x14366A, 0x050C1E),
        groups: [
            Group(layers: [
                Layer(name: "2 Table", path: table, colour: 0xFFFFFF, opacity: 0.95),
                Layer(name: "2 Crown Right", path: crownRight, colour: 0xD8F4FF, opacity: 0.7),
                Layer(name: "2 Crown Left", path: crownLeft, colour: 0xD8F4FF, opacity: 0.55),
            ], translucency: 0.4, shadowOpacity: 0.35, lighting: "individual"),
            Group(layers: [
                Layer(name: "1 Pavilion Right", path: pavilionRight, colour: 0xBFEAFF, opacity: 0.6),
                Layer(name: "1 Pavilion Middle", path: pavilionMiddle, colour: 0xFFFFFF, opacity: 0.42),
                Layer(name: "1 Pavilion Left", path: pavilionLeft, colour: 0xBFEAFF, opacity: 0.82),
            ], translucency: 0.4, shadowOpacity: 0.35, lighting: "individual"),
        ])
}

/// A drop seen from above and the rings it leaves on still water.
func pellucidRipple() -> Candidate {
    return Candidate(
        name: "Pellucid-Ripple",
        background: (0x22A0BA, 0x0A3A4D),
        darkBackground: (0x0B3A48, 0x03141B),
        groups: [
            Group(layers: [Layer(name: "3 Drop", path: disc(512, 512, 122), colour: 0xFFFFFF, opacity: 0.92)],
                  translucency: 0.3, shadowOpacity: 0.45),
            Group(layers: [Layer(name: "2 Inner Ring", path: ring(512, 512, outer: 236, inner: 192), colour: 0xFFFFFF, opacity: 0.6)],
                  translucency: 0.4, shadowOpacity: 0.3),
            Group(layers: [Layer(name: "1 Outer Ring", path: ring(512, 512, outer: 332, inner: 296), colour: 0xFFFFFF, opacity: 0.32)],
                  translucency: 0.4, shadowOpacity: 0.2),
        ])
}

// MARK: Perspica spectacles in origin faces (round 3)

struct Palette3 {
    var background: (UInt32, UInt32)
    var darkBackground: (UInt32, UInt32)
    var frame: UInt32
    var darkFrame: UInt32
    var ink: UInt32
    var darkInk: UInt32
    var coolLens: UInt32
    var warmLens: UInt32
    var lensOpacity: Double
    /// White ink and frame in the clear and tinted appearances, for the light
    /// palettes whose dark ink greys out there.
    var whiteInMono = false
    /// The letters' colour in the clear and tinted appearances, when white
    /// would vanish on clear lenses.
    var monoInk: UInt32? = nil
    /// Below 1, the frame is translucent glass rather than a solid colour.
    var frameOpacity: Double = 1
    var frameTranslucency: Double? = nil
}

/// Thickens a thin outline by `width` (half on each side), so brush and
/// italic hairlines survive at small sizes without changing the letterform.
func embolden(_ path: CGPath, by width: CGFloat) -> CGPath {
    guard width > 0 else { return path }
    return path.union(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

/// The spectacles the canvas sketch started from: A in the left lens, あ in
/// the right, each set in a face from its own writing tradition.
func perspicaSpectaclesIn(name: String, latin: CTFont, latinHeight: CGFloat,
                          kana: CTFont, kanaHeight: CGFloat, bolden: CGFloat = 0,
                          palette: Palette3) -> Candidate {
    let mono: UInt32? = palette.whiteInMono ? 0xFFFFFF : nil
    let monoInk = palette.monoInk ?? mono
    let left: CGFloat = 318, right: CGFloat = 706, cy: CGFloat = 548
    let outer: CGFloat = 176, inner: CGFloat = 126, mid = (outer + inner) / 2
    func point(_ cx: CGFloat, _ degrees: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
    let bridge = stroke({ p in
        p.move(to: point(left, -34, mid))
        p.addQuadCurve(to: point(right, 214, mid), control: CGPoint(x: 512, y: cy - 158))
    }, width: 44)
    let temples = stroke({ p in
        p.move(to: point(left, 198, mid)); p.addLine(to: CGPoint(x: 112, y: cy - 104))
        p.move(to: point(right, -18, mid)); p.addLine(to: CGPoint(x: 912, y: cy - 104))
    }, width: 44)
    let frame = unite([ring(left, cy, outer: outer, inner: inner),
                       ring(right, cy, outer: outer, inner: inner), bridge, temples])
    return Candidate(
        name: name,
        background: palette.background,
        darkBackground: palette.darkBackground,
        groups: [
            Group(layers: [Layer(name: "4 Frame", path: frame, colour: palette.frame, darkColour: palette.darkFrame,
                                 opacity: palette.frameOpacity, monoColour: mono)],
                  translucency: palette.frameTranslucency, shadowOpacity: 0.5),
            Group(layers: [
                Layer(name: "3 Kana",
                      path: embolden(glyph("あ", font: kana, height: kanaHeight, cx: right, cy: cy + 2), by: bolden),
                      colour: palette.ink, darkColour: palette.darkInk, monoColour: monoInk),
                Layer(name: "3 Latin",
                      path: embolden(glyph("A", font: latin, height: latinHeight, cx: left, cy: cy), by: bolden),
                      colour: palette.ink, darkColour: palette.darkInk, monoColour: monoInk),
            ], translucency: nil, specular: false, shadowOpacity: 0.2, lighting: "individual"),
            Group(layers: [
                Layer(name: "2 Lens Right", path: disc(right, cy, inner + 6), colour: palette.warmLens, opacity: palette.lensOpacity),
                Layer(name: "2 Lens Left", path: disc(left, cy, inner + 6), colour: palette.coolLens, opacity: palette.lensOpacity),
            ], translucency: 0.45, shadowOpacity: 0.2, lighting: "individual"),
        ])
}

/// Stone and woodblock: Roman inscriptional capitals and printed Mincho, on
/// the light sketch palette.
func perspicaStone() -> Candidate {
    perspicaSpectaclesIn(
        name: "Perspica-Stone", latin: cinzel, latinHeight: 148, kana: shipporiMincho, kanaHeight: 164,
        palette: Palette3(background: (0xFBFCFF, 0xD3DCF0), darkBackground: (0x1C2654, 0x0A0F26),
                          frame: 0x1C2340, darkFrame: 0xEEF1FB, ink: 0x1C2340, darkInk: 0xFFFFFF,
                          coolLens: 0x5B8CFF, warmLens: 0xFF8A9A, lensOpacity: 0.5, whiteInMono: true))
}

/// Quill and brush: the Renaissance italic and brush-written kana, in sumi on
/// washi, with an indigo lens and a vermilion one.
func perspicaBrush() -> Candidate {
    perspicaSpectaclesIn(
        name: "Perspica-Brush", latin: cormorantItalic, latinHeight: 172, kana: yujiSyuku, kanaHeight: 182,
        bolden: 8,
        palette: Palette3(background: (0xFBF9F4, 0xE3DCCF), darkBackground: (0x26221D, 0x0E0C0A),
                          frame: 0x1E1D22, darkFrame: 0xF3EFE6, ink: 0x1E1D22, darkInk: 0xF6F1E7,
                          coolLens: 0x3F5BD8, warmLens: 0xE2553A, lensOpacity: 0.42, whiteInMono: true))
}

/// Gold on indigo, after the Heian sutras written in gold ink on indigo-dyed
/// paper (紺紙金泥): ornamented capitals and brush kana in gold.
func perspicaGold() -> Candidate {
    perspicaSpectaclesIn(
        name: "Perspica-Gold", latin: cinzelDecorative, latinHeight: 150, kana: yujiSyuku, kanaHeight: 180,
        bolden: 6,
        palette: Palette3(background: (0x24337A, 0x0D1238), darkBackground: (0x151C48, 0x05071A),
                          frame: 0xD9B46C, darkFrame: 0xD9B46C, ink: 0xF0D592, darkInk: 0xF0D592,
                          coolLens: 0x4F8CFF, warmLens: 0xB36BFF, lensOpacity: 0.34))
}

/// 紺紙金泥 in clear glass: the same spectacles and letters, the indigo paper
/// turned into pale glass, the frame and lenses clear, only the letters gold.
func perspicaGoldGlass() -> Candidate {
    perspicaSpectaclesIn(
        name: "Perspica-GoldGlass", latin: cinzelDecorative, latinHeight: 150, kana: yujiSyuku, kanaHeight: 180,
        bolden: 6,
        palette: Palette3(background: (0xF2F5F9, 0xC4CDD9), darkBackground: (0x3A404A, 0x111318),
                          frame: 0xFFFFFF, darkFrame: 0xF2F4F8, ink: 0xA8822F, darkInk: 0xEBCB83,
                          coolLens: 0xFFFFFF, warmLens: 0xFFFFFF, lensOpacity: 0.5,
                          monoInk: 0x000000, frameOpacity: 0.9, frameTranslucency: 0.45))
}

/// The chosen icon (2026-11-09): the quill italic A and the brush あ of
/// Perspica-Brush, in the light colours of Perspica-Stone.
func perspicaFinal() -> Candidate {
    perspicaSpectaclesIn(
        name: "Perspica-Final", latin: cormorantItalic, latinHeight: 172, kana: yujiSyuku, kanaHeight: 182,
        bolden: 8,
        palette: Palette3(background: (0xFBFCFF, 0xD3DCF0), darkBackground: (0x1C2654, 0x0A0F26),
                          frame: 0x1C2340, darkFrame: 0xEEF1FB, ink: 0x1C2340, darkInk: 0xFFFFFF,
                          coolLens: 0x5B8CFF, warmLens: 0xFF8A9A, lensOpacity: 0.5, whiteInMono: true))
}

// MARK: main

let out = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
for candidate in [perspicaSpectacles(), perspicaLens(), pellucidPane(), pellucidDrop(),
                  perspicaDuo(), perspicaFrames(), perspicaPrism(),
                  pellucidPanes(), pellucidCrystal(), pellucidRipple(),
                  perspicaStone(), perspicaBrush(), perspicaGold(), perspicaGoldGlass(), perspicaFinal()] {
    try write(candidate, into: out)
}
