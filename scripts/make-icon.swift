// Draws the Brise app icon with CoreGraphics and writes a 1024 px PNG.
// A clean white tile with three blue wind gusts.
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

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: rgb(0x0B2A5B, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Background: white with the faintest sky tint toward the bottom.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xEEF5FF)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// MARK: Wind gusts (drawn from scratch: Apple's license doesn't allow SF Symbols in app icons)

/// A horizontal gust from `startX` to `endX` at height `y`, optionally ending in a curl of radius `r`.
/// `up` curls above the line, otherwise below.
func gust(y: CGFloat, startX: CGFloat, endX: CGFloat, r: CGFloat = 0, up: Bool = true, sweep: CGFloat = 1.4) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: startX, y: y))
    p.addLine(to: CGPoint(x: endX, y: y))
    guard r > 0 else { return p }
    let center = CGPoint(x: endX, y: up ? y - r : y + r)
    let startAngle: CGFloat = up ? .pi / 2 : -.pi / 2
    let endAngle = up ? startAngle - .pi * sweep : startAngle + .pi * sweep
    p.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: up)
    return p
}

let width: CGFloat = 54
let gusts = [
    gust(y: 395, startX: 250, endX: 600, r: 78, up: true),     // top: curls up
    gust(y: 520, startX: 200, endX: 760),                       // middle: long and straight
    gust(y: 645, startX: 270, endX: 560, r: 78, up: false),     // bottom: curls down
]

let blue = CGGradient(colorsSpace: space, colors: [rgb(0x3E9BFF), rgb(0x1F6BFF)] as CFArray, locations: [0, 1])!
for g in gusts {
    ctx.saveGState()
    ctx.addPath(g)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(blue, start: CGPoint(x: 200, y: 260), end: CGPoint(x: 820, y: 760),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Fine edge so the white tile reads on light backgrounds.
ctx.addPath(tilePath)
ctx.setLineWidth(2)
ctx.setStrokeColor(rgb(0x0B2A5B, 0.08))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✔︎ \(output)")
