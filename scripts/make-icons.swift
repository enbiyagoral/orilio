// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

// Draws Orilio's raster brand assets from the icon's proportions (the M5 Icon and Favicon designs):
// the app icon in three appearances, the web icons and the DMG background.
// Usage: swift scripts/make-icons.swift   (from the repository root; rewrites the files it owns)
import AppKit
import CoreText

// MARK: - The oriel

enum Look { case standard, dark, tinted, light }

/// Every size derives from the tile size S, rounded like the design does.
struct Oriel {
    let s: CGFloat
    let small: Bool

    init(_ s: CGFloat) {
        self.s = s
        small = s <= 32
    }

    var radius: CGFloat { (s * (small ? 0.2 : 0.225)).rounded() }
    var islandWidth: CGFloat { (s * (small ? 0.6 : 0.46)).rounded() }
    var islandHeight: CGFloat { max(3, (s * (small ? 0.2 : 0.15)).rounded()) }
    var islandRadius: CGFloat { max(1, (s * 0.08).rounded()) }
    var lineTop: CGFloat { max(1, (s * (small ? 0.07 : 0.055)).rounded()) }
    var lineWidth: CGFloat { max(small ? 5 : 4, (s * (small ? 0.3 : 0.2)).rounded()) }
    var lineHeight: CGFloat { max(small ? 2 : 1, (s * 0.035).rounded()) }
    var lineGlow: CGFloat { max(2, (s * 0.08).rounded()) }
    var edge: CGFloat { max(1, (s / 256).rounded()) }
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// A CSS `linear-gradient(<angle>deg, …)` across `rect` (y down).
func linear(_ cg: CGContext, _ rect: CGRect, angle: CGFloat, _ stops: [(CGColor, CGFloat)]) {
    let t = angle * .pi / 180
    let dir = CGPoint(x: sin(t), y: -cos(t)) // y down: 0° points up, 180° down
    let length = abs(rect.width * sin(t)) + abs(rect.height * cos(t))
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let start = CGPoint(x: c.x - dir.x * length / 2, y: c.y - dir.y * length / 2)
    let end = CGPoint(x: c.x + dir.x * length / 2, y: c.y + dir.y * length / 2)
    let gradient = CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
    cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A CSS `radial-gradient(rx ry at x y, color 0%, transparent 70%)`.
func radial(_ cg: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, _ color: CGColor, fadeAt: CGFloat = 0.7) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.scaleBy(x: 1, y: ry / rx)
    let clear = color.copy(alpha: 0)!
    let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, fadeAt])!
    cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
    cg.restoreGState()
}

func continuousRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

/// The island: flush with the tile's top edge, rounded only at the bottom.
func islandPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.closeSubpath()
    return p
}

/// Draws the tile of size `o.s` at `origin` (y down).
func drawTile(_ cg: CGContext, _ o: Oriel, at origin: CGPoint, look: Look) {
    let tile = CGRect(origin: origin, size: CGSize(width: o.s, height: o.s))
    let shape = continuousRect(tile, o.radius)
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    switch look {
    case .standard:
        linear(cg, tile, angle: 165, [(rgb(0x2A3244), 0), (rgb(0x12151E), 0.55), (rgb(0x08090D), 1)])
        radial(cg, center: CGPoint(x: tile.midX, y: tile.minY + o.s * 0.22), rx: o.s * 0.7, ry: o.s * 0.55, rgb(0x2BFFB8, 0.22))
    case .dark:
        linear(cg, tile, angle: 165, [(rgb(0x1A1D26), 0), (rgb(0x050507), 1)])
        radial(cg, center: CGPoint(x: tile.midX, y: tile.minY + o.s * 0.22), rx: o.s * 0.7, ry: o.s * 0.55, rgb(0x2BFFB8, 0.14))
    case .tinted:
        // Monochrome: macOS tints it; the light line is the bright element.
        linear(cg, tile, angle: 165, [(rgb(0x5A5A5A), 0), (rgb(0x262626), 1)])
    case .light:
        linear(cg, tile, angle: 165, [(rgb(0xF2F5F8), 0), (rgb(0xD3DAE2), 1)])
    }

    // The island, with a soft mint glow under it (none in tinted and light).
    let island = CGRect(x: (tile.midX - o.islandWidth / 2).rounded(), y: tile.minY, width: o.islandWidth, height: o.islandHeight)
    cg.saveGState()
    if look == .standard || look == .dark {
        cg.setShadow(offset: CGSize(width: 0, height: (o.s * 0.04).rounded()), blur: (o.s * 0.16).rounded(), color: rgb(0x2BFFB8, 0.28))
    }
    cg.addPath(islandPath(island, o.islandRadius))
    cg.setFillColor(look == .tinted ? rgb(0x000000, 0.85) : rgb(0x000000))
    cg.fillPath()
    cg.restoreGState()

    // The light line inside it.
    let line = CGRect(x: (tile.midX - o.lineWidth / 2).rounded(), y: tile.minY + o.lineTop, width: o.lineWidth, height: o.lineHeight)
    cg.saveGState()
    let lineColor: CGColor = switch look {
    case .light: rgb(0x13B887)
    case .tinted: rgb(0xFFFFFF)
    default: rgb(0x2BFFB8)
    }
    if look == .standard || look == .dark {
        cg.setShadow(offset: .zero, blur: o.lineGlow * (look == .dark ? 1.5 : 1), color: rgb(0x2BFFB8))
    }
    cg.addPath(continuousRect(line, o.lineHeight / 2))
    cg.setFillColor(lineColor)
    cg.fillPath()
    cg.restoreGState()
    cg.restoreGState()

    // A 1 px inner edge.
    cg.saveGState()
    cg.addPath(continuousRect(tile.insetBy(dx: o.edge / 2, dy: o.edge / 2), o.radius - o.edge / 2))
    cg.setStrokeColor(look == .light ? rgb(0x000000, 0.08) : rgb(0xFFFFFF, look == .standard ? 0.1 : 0.12))
    cg.setLineWidth(o.edge)
    cg.strokePath()
    cg.restoreGState()
}

func bitmap(_ w: Int, _ h: Int, opaque: Bool = false, draw: (CGContext) -> Void) -> CGImage {
    let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.translateBy(x: 0, y: CGFloat(h))
    cg.scaleBy(x: 1, y: -1) // y down, like the designs
    draw(cg)
    return cg.makeImage()!
}

func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// A macOS app icon: the tile at 824/1024 of the canvas with a soft drop shadow (Apple's icon grid).
func appIcon(_ px: Int, look: Look) -> CGImage {
    bitmap(px, px) { cg in
        let canvas = CGFloat(px)
        let s = px <= 32 ? canvas - 2 * (canvas * 0.06).rounded() : (canvas * 824 / 1024).rounded()
        let inset = ((canvas - s) / 2).rounded()
        cg.saveGState()
        if px > 32 {
            cg.setShadow(offset: CGSize(width: 0, height: canvas * 12 / 1024), blur: canvas * 26 / 1024, color: rgb(0x000000, 0.3))
            cg.addPath(continuousRect(CGRect(x: inset, y: inset, width: s, height: s), (s * 0.225).rounded()))
            cg.setFillColor(rgb(0x08090D))
            cg.fillPath()
        }
        cg.restoreGState()
        drawTile(cg, Oriel(s), at: CGPoint(x: inset, y: inset), look: look)
    }
}

// MARK: - Outputs

let root = FileManager.default.currentDirectoryPath
let iconset = "\(root)/Resources/Assets.xcassets/AppIcon.appiconset"
var images: [[String: Any]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        for (look, suffix, appearance) in [(Look.standard, "", nil), (.dark, "-dark", "dark"), (.tinted, "-tinted", "tinted")] as [(Look, String, String?)] {
            let name = "icon-\(size)@\(scale)x\(suffix).png"
            write(appIcon(size * scale, look: look), "\(iconset)/\(name)")
            var entry: [String: Any] = ["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name]
            if let appearance { entry["appearances"] = [["appearance": "luminosity", "value": appearance]] }
            images.append(entry)
        }
    }
}
func json(_ object: Any, _ path: String) {
    try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
}
json(["images": images, "info": ["author": "xcode", "version": 1]], "\(iconset)/Contents.json")
json(["info": ["author": "xcode", "version": 1]], "\(root)/Resources/Assets.xcassets/Contents.json")

// Web icons: the tile full bleed; the touch icon has no transparency.
for (px, file) in [(16, "favicon-16.png"), (32, "favicon-32.png")] {
    write(bitmap(px, px) { drawTile($0, Oriel(CGFloat(px)), at: .zero, look: .standard) }, "\(root)/web/\(file)")
}
write(bitmap(180, 180, opaque: true) { cg in
    cg.setFillColor(rgb(0x08090D))
    cg.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
    drawTile(cg, Oriel(180), at: .zero, look: .standard)
}, "\(root)/web/apple-touch-icon.png")
for (px, file) in [(192, "icon-192.png"), (512, "icon-512.png")] {
    write(bitmap(px, px) { drawTile($0, Oriel(CGFloat(px)), at: .zero, look: .standard) }, "\(root)/web/\(file)")
}

// MARK: - DMG background (the M5 Icon design's DMG window, 600 × 400)

func text(_ cg: CGContext, _ string: String, size: CGFloat, color: CGColor, centerX: CGFloat, baseline: CGFloat, weight: NSFont.Weight = .regular) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    cg.saveGState()
    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // the context is y down
    cg.textPosition = CGPoint(x: centerX - width / 2, y: baseline)
    CTLineDraw(line, cg)
    cg.restoreGState()
}

for scale in [1, 2] {
    let k = CGFloat(scale)
    let image = bitmap(600 * scale, 400 * scale, opaque: true) { cg in
        cg.scaleBy(x: k, y: k)
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        linear(cg, rect, angle: 160, [(rgb(0x14171F), 0), (rgb(0x08090C), 1)])
        radial(cg, center: CGPoint(x: 300, y: 0), rx: 300, ry: 220, rgb(0x2BFFB8, 0.16))
        // The dashed arrow from the app (x 160) to Applications (x 440), at the icons' middle (y 190).
        cg.setStrokeColor(rgb(0xFFFFFF, 0.35))
        cg.setLineWidth(2)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: [6, 7])
        cg.move(to: CGPoint(x: 240, y: 190))
        cg.addLine(to: CGPoint(x: 352, y: 190))
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.move(to: CGPoint(x: 344, y: 182))
        cg.addLine(to: CGPoint(x: 354, y: 190))
        cg.addLine(to: CGPoint(x: 344, y: 198))
        cg.strokePath()
        text(cg, "Drag Orilio into Applications. Free, no account needed.", size: 13, color: rgb(0xFFFFFF, 0.6), centerX: 300, baseline: 370)
    }
    write(image, "\(root)/Resources/DMG/background\(scale == 2 ? "@2x" : "").png")
}
print("Wrote the app icon set, web icons and the DMG background.")
