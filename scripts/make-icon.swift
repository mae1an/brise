// Draws the Brise app icon with CoreGraphics and writes a 1024 px PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in y-down coordinates like a design tool.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824 pt rounded square centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x0B1640))
ctx.fillPath()
ctx.restoreGState()

// Background: deep night blue → ocean teal.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x0A0F2E), rgb(0x142A66), rgb(0x0C6E92)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 120), end: CGPoint(x: 860, y: 920), options: [])

// Warm glow bottom-left (the heat) and cool glow top-right (the breeze).
let warm = CGGradient(colorsSpace: space, colors: [rgb(0xFF6A2B, 0.38), rgb(0xFF6A2B, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(warm, startCenter: CGPoint(x: 170, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 170, y: 860), endRadius: 400, options: [])
let cool = CGGradient(colorsSpace: space, colors: [rgb(0x6FF3FF, 0.30), rgb(0x6FF3FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(cool, startCenter: CGPoint(x: 820, y: 220), startRadius: 0,
                       endCenter: CGPoint(x: 820, y: 220), endRadius: 420, options: [])

// Glassy top highlight.
let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// MARK: Wind gusts — straight lines that curl at the end, like a stylised breeze.

/// A horizontal gust from `startX` to `endX` at height `y`, ending in a curl of radius `r`.
/// `up` curls above the line, otherwise below.
func gust(y: CGFloat, startX: CGFloat, endX: CGFloat, r: CGFloat, up: Bool, sweep: CGFloat = 1.45) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: startX, y: y))
    p.addLine(to: CGPoint(x: endX, y: y))
    let center = CGPoint(x: endX, y: up ? y - r : y + r)
    let startAngle: CGFloat = up ? .pi / 2 : -.pi / 2          // bottom (up) / top (down) of the circle
    let endAngle = up ? startAngle - .pi * sweep : startAngle + .pi * sweep
    p.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: up)
    return p
}

let width: CGFloat = 58
let gusts = [
    gust(y: 380, startX: 250, endX: 480, r: 66, up: true),
    gust(y: 525, startX: 200, endX: 715, r: 86, up: true, sweep: 1.5),
    gust(y: 665, startX: 305, endX: 590, r: 72, up: false),
]

// Soft cyan glow behind the strokes.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x7FE9FF, 0.5))
for g in gusts {
    ctx.addPath(g)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0x9FEFFF, 0.6))
    ctx.strokePath()
}
ctx.restoreGState()

// Strokes filled with a warm → white → icy gradient (hot air in, cool breeze out).
let windGradient = CGGradient(colorsSpace: space,
                              colors: [rgb(0xFF8A3D), rgb(0xFFD7A8), rgb(0xFFFFFF), rgb(0x8FF0FF)] as CFArray,
                              locations: [0, 0.3, 0.55, 1])!
for g in gusts {
    ctx.saveGState()
    ctx.addPath(g)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(windGradient, start: CGPoint(x: 200, y: 0), end: CGPoint(x: 800, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Fine edge on the tile for definition on light backgrounds.
ctx.addPath(tilePath)
ctx.setLineWidth(2)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✔︎ \(output)")
