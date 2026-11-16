// Draws the app icon (light, dark and tinted variants) into the asset catalog.
// Usage: swift tools/make-icon.swift [output-dir]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "OBSCamera/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

struct Palette {
    var bgTop: CGColor, bgBottom: CGColor
    var glyph: CGColor          // lens ring and waves
    var ringInner: CGColor      // dark gap between ring and glass
    var glassTop: CGColor, glassBottom: CGColor
    var core: CGColor
    var dot: CGColor, dotBorder: CGColor
}

let light = Palette(bgTop: rgb(0x6A6CF6), bgBottom: rgb(0x2C2E9E),
                    glyph: rgb(0xFFFFFF), ringInner: rgb(0x1A1C3A),
                    glassTop: rgb(0x4A4FA8), glassBottom: rgb(0x0D0E22),
                    core: rgb(0x23266A), dot: rgb(0xFF3B30), dotBorder: rgb(0xFFFFFF))
let dark = Palette(bgTop: rgb(0x1E2036), bgBottom: rgb(0x0B0C16),
                   glyph: rgb(0x8E90FF), ringInner: rgb(0x0B0C16),
                   glassTop: rgb(0x3A3E8C), glassBottom: rgb(0x07080F),
                   core: rgb(0x1C1F55), dot: rgb(0xFF453A), dotBorder: rgb(0x1E2036))
let tinted = Palette(bgTop: rgb(0x000000), bgBottom: rgb(0x000000),
                     glyph: rgb(0xFFFFFF), ringInner: rgb(0x000000),
                     glassTop: rgb(0x5A5A5A), glassBottom: rgb(0x1A1A1A),
                     core: rgb(0x333333), dot: rgb(0xFFFFFF), dotBorder: rgb(0x000000))

func circle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func linear(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor, from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func draw(_ p: Palette) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, like a design tool.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    let s = CGFloat(size)
    let center = CGPoint(x: s / 2, y: s / 2)

    // Background.
    linear(ctx, p.bgTop, p.bgBottom, from: .zero, to: CGPoint(x: s * 0.6, y: s))

    // Broadcast waves on both sides of the lens.
    ctx.setStrokeColor(p.glyph)
    ctx.setLineCap(.round)
    let span = CGFloat.pi * 0.2
    for (radius, width, alpha) in [(CGFloat(292), CGFloat(40), CGFloat(1)), (370, 40, 0.55)] {
        ctx.setLineWidth(width)
        ctx.setAlpha(alpha)
        for mid in [CGFloat(0), .pi] {
            ctx.beginPath()
            ctx.addArc(center: center, radius: radius, startAngle: mid - span, endAngle: mid + span, clockwise: false)
            ctx.strokePath()
        }
    }
    ctx.setAlpha(1)

    // Lens: outer ring, dark gap, glass with gradient, core and highlight.
    ctx.setFillColor(p.glyph)
    ctx.fillEllipse(in: circle(ctx, center, 214))
    ctx.setFillColor(p.ringInner)
    ctx.fillEllipse(in: circle(ctx, center, 176))

    ctx.saveGState()
    ctx.addEllipse(in: circle(ctx, center, 156))
    ctx.clip()
    linear(ctx, p.glassTop, p.glassBottom,
           from: CGPoint(x: center.x - 120, y: center.y - 156), to: CGPoint(x: center.x + 80, y: center.y + 156))
    ctx.setFillColor(p.core)
    ctx.fillEllipse(in: circle(ctx, center, 70))
    ctx.restoreGState()

    ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
    ctx.fillEllipse(in: circle(ctx, CGPoint(x: center.x - 58, y: center.y - 58), 36))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
    ctx.fillEllipse(in: circle(ctx, CGPoint(x: center.x + 50, y: center.y + 60), 16))

    // "Live" dot on the ring, top-right.
    let dotCenter = CGPoint(x: center.x + 140, y: center.y - 140)
    ctx.setFillColor(p.dotBorder)
    ctx.fillEllipse(in: circle(ctx, dotCenter, 50))
    ctx.setFillColor(p.dot)
    ctx.fillEllipse(in: circle(ctx, dotCenter, 38))

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("Failed to write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("Wrote \(url.path)")
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
write(draw(light), "AppIcon.png")
write(draw(dark), "AppIcon-Dark.png")
write(draw(tinted), "AppIcon-Tinted.png")
