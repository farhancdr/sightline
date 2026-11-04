// Renders the raster assets that are generated from SVG sources:
//   Resources/dmg-background.png (660×400), Resources/dmg-background@2x.png (1320×800),
//   Resources/Design/banner.png (1280×640, banner-bg.svg + the app icon).
// Text is drawn with the system font (SF Pro) here, because macOS's SVG renderer ignores
// font-weight, letter-spacing and per-<tspan> colors. Keep the strings below in sync with the SVGs.
// Usage (from the repo root): swift scripts/render-assets.swift
import AppKit

let design = URL(fileURLWithPath: "Resources/Design")

func render(size: NSSize, scale: CGFloat, to output: URL, draw: (NSRect) -> Void) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: output)
    print("wrote \(output.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

/// SVG artwork with its <text> elements removed (they're drawn natively below).
func artwork(_ path: String) -> NSImage {
    let url = design.appendingPathComponent(path)
    guard var svg = try? String(contentsOf: url, encoding: .utf8) else { fatalError("missing \(path)") }
    svg = svg.replacingOccurrences(of: #"<text[\s\S]*?</text>"#, with: "", options: .regularExpression)
    guard let image = NSImage(data: Data(svg.utf8)) else { fatalError("can't render \(path)") }
    return image
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Draws text with its baseline `baselineFromTop` points below the top edge (SVG coordinates).
/// `x` is the left edge, or the center when `centered`.
func text(_ parts: [(String, NSColor)], font: NSFont, kern: CGFloat = 0, x: CGFloat, baselineFromTop: CGFloat,
          centered: Bool = false, in canvas: NSRect) {
    let string = NSMutableAttributedString()
    for (part, color) in parts {
        string.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: color, .kern: kern]))
    }
    let width = string.size().width
    let originX = centered ? x - width / 2 : x
    // draw(at:) takes the bottom-left of the line box; the baseline sits |descender| above it.
    let originY = canvas.height - baselineFromTop + font.descender
    string.draw(at: NSPoint(x: originX, y: originY))
}

let ink = rgb(0x1F2328)
let muted = rgb(0x59636E)
let brand = rgb(0x2A639B)

// DMG installer background (matches source/dmg-background.svg).
let dmg = artwork("source/dmg-background.svg")
for (scale, name) in [(CGFloat(1), "dmg-background.png"), (2, "dmg-background@2x.png")] {
    try render(size: NSSize(width: 660, height: 400), scale: scale,
               to: URL(fileURLWithPath: "Resources/\(name)")) { canvas in
        dmg.draw(in: canvas)
        text([("Drag Sightline to Applications", ink)], font: .systemFont(ofSize: 20, weight: .semibold),
             x: 330, baselineFromTop: 76, centered: true, in: canvas)
        text([("First launch: System Settings → Privacy & Security → Open Anyway", muted)],
             font: .systemFont(ofSize: 11), x: 330, baselineFromTop: 372, centered: true, in: canvas)
    }
}

// README banner (matches source/banner-bg.svg) with the app icon on the left.
let banner = artwork("source/banner-bg.svg")
guard let icon = NSImage(contentsOf: design.appendingPathComponent("AppIcon-master.png")) else { fatalError("icon") }
try render(size: NSSize(width: 1280, height: 640), scale: 1, to: design.appendingPathComponent("banner.png")) { canvas in
    banner.draw(in: canvas)
    // The master icon's squircle is ~824/1024 of its canvas; this makes the squircle ~260 pt.
    let side: CGFloat = 323
    icon.draw(in: NSRect(x: 148, y: (canvas.height - side) / 2, width: side, height: side))
    text([("Sight", ink), ("line", brand)], font: .systemFont(ofSize: 112, weight: .bold), kern: -3,
         x: 500, baselineFromTop: 330, in: canvas)
    text([("Review AI agent changes across every repo", muted)], font: .systemFont(ofSize: 34),
         x: 504, baselineFromTop: 396, in: canvas)
}
