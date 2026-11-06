import AppKit

/// Custom-drawn Touch Bar pieces. The Touch Bar is 30 pt tall on a pure black OLED,
/// so everything is a capsule with soft gradients that glow when active.
enum TBStyle {
    static let height: CGFloat = 30
    static let idle = NSColor(white: 1, alpha: 0.11)
    static let text = NSColor(white: 1, alpha: 0.92)
    static let dim = NSColor(white: 1, alpha: 0.45)

    /// Green → yellow → orange → red, same thresholds as the panel.
    static func heat(_ t: Double?) -> NSColor {
        guard let t else { return .systemGray }
        switch t {
        case ..<60: return .systemGreen
        case ..<80: return .systemYellow
        case ..<92: return .systemOrange
        default: return .systemRed
        }
    }

    static func capsule(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    static func draw(_ string: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let size = (string as NSString).size(withAttributes: attrs)
        let r = NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height)
        (string as NSString).draw(in: r, withAttributes: attrs)
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Base: a borderless button whose whole look is drawn by `drawContent`.
class TBDrawnButton: NSButton {
    let fixedWidth: CGFloat

    init(width: CGFloat, target: AnyObject?, action: Selector?) {
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: TBStyle.height))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: TBStyle.height) }

    /// NSButton is flipped by default; draw with y going up like the rest of AppKit.
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawContent(bounds.insetBy(dx: 0, dy: 0))
        if isHighlighted {
            NSColor(white: 1, alpha: 0.15).setFill()
            TBStyle.capsule(bounds).fill()
        }
    }

    func drawContent(_ rect: NSRect) {}
}

/// Control Strip: "77°" on a heat-coloured capsule with a thin level bar.
final class TBTrayButton: TBDrawnButton {
    var temp: Double? { didSet { needsDisplay = true } }
    var fansForced = false { didSet { needsDisplay = true } }

    override func drawContent(_ rect: NSRect) {
        let color = TBStyle.heat(temp)
        let shape = TBStyle.capsule(rect.insetBy(dx: 2, dy: 1))
        NSGradient(starting: color.withAlphaComponent(0.55), ending: color.withAlphaComponent(0.22))?.draw(in: shape, angle: -90)
        if fansForced {
            NSColor.systemOrange.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        // Level bar: 30 °C → 100 °C
        let level = CGFloat(min(1, max(0, ((temp ?? 30) - 30) / 70)))
        let barRect = NSRect(x: rect.minX + 10, y: rect.minY + 4, width: (rect.width - 20) * level, height: 2)
        color.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        let text = temp.map { "\(Int($0.rounded()))°" } ?? "—"
        TBStyle.draw(text, in: rect.offsetBy(dx: 0, dy: 1.5), font: .monospacedDigitSystemFont(ofSize: 15, weight: .bold), color: .white)
    }
}

/// CPU heat gauge: label, big value, and a gradient fill showing how hot it is.
final class TBHeatGauge: TBDrawnButton {
    var label = "CPU"
    var temp: Double? { didSet { needsDisplay = true } }

    override func drawContent(_ rect: NSRect) {
        let shape = TBStyle.capsule(rect)
        TBStyle.idle.setFill()
        shape.fill()
        let color = TBStyle.heat(temp)
        let level = CGFloat(min(1, max(0.08, ((temp ?? 30) - 30) / 70)))
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * level, height: rect.height)
        NSGradient(colors: [NSColor.systemGreen.withAlphaComponent(0.5), color.withAlphaComponent(0.85)])?.draw(in: fill, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        TBStyle.draw(label, in: NSRect(x: rect.minX + 12, y: rect.minY, width: 40, height: rect.height),
                     font: .systemFont(ofSize: 11, weight: .bold), color: TBStyle.text.withAlphaComponent(0.8), align: .left)
        TBStyle.draw(temp.map { "\(Int($0.rounded()))°" } ?? "—",
                     in: NSRect(x: rect.maxX - 56, y: rect.minY, width: 46, height: rect.height),
                     font: .monospacedDigitSystemFont(ofSize: 16, weight: .bold), color: .white, align: .right)
    }
}

/// Live CPU temperature curve with a glowing gradient under it.
final class TBSparkline: TBDrawnButton {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var secondary: String = "" { didSet { needsDisplay = true } }

    override func drawContent(_ rect: NSRect) {
        let shape = TBStyle.capsule(rect)
        NSColor(white: 1, alpha: 0.06).setFill()
        shape.fill()
        guard values.count > 2, let lo = values.min(), let hi = values.max() else { return }
        let span = max(hi - lo, 6)
        let inset = rect.insetBy(dx: 12, dy: 5)
        let points = values.enumerated().map { i, v in
            NSPoint(x: inset.minX + inset.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: inset.minY + inset.height * CGFloat((v - lo) / span))
        }
        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: inset.maxX, y: rect.minY))
        area.line(to: NSPoint(x: inset.minX, y: rect.minY))
        area.close()
        let color = TBStyle.heat(values.last)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: color.withAlphaComponent(0.35), ending: color.withAlphaComponent(0))?.draw(in: area, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        color.setStroke()
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        line.stroke()
        if let last = points.last {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)).fill()
        }
        if !secondary.isEmpty {
            TBStyle.draw(secondary, in: NSRect(x: rect.minX + 12, y: rect.maxY - 13, width: rect.width - 24, height: 12),
                         font: .systemFont(ofSize: 9, weight: .semibold), color: TBStyle.dim, align: .left)
        }
    }
}

/// A fan glyph that actually spins (speed follows the rpm) + the rpm. Tap: Auto ⇄ Max.
final class TBFanButton: TBDrawnButton {
    var rpm: Double = 0 { didSet { needsDisplay = true } }
    var forced = false { didSet { needsDisplay = true } }
    var enabledLook = true { didSet { needsDisplay = true } }
    var modeLabel = "Auto"
    private var angle: CGFloat = 0
    private var timer: Timer?

    func startSpinning() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Visual speed only: ~1 turn/s per 1000 rpm, so it reads as "faster" without strobing.
                self.angle -= CGFloat(self.rpm / 1000) * 12
                self.needsDisplay = true
            }
        }
    }

    func stopSpinning() {
        timer?.invalidate()
        timer = nil
    }

    override func drawContent(_ rect: NSRect) {
        let shape = TBStyle.capsule(rect)
        if forced {
            NSGradient(starting: NSColor.systemOrange.withAlphaComponent(0.85), ending: NSColor.systemRed.withAlphaComponent(0.65))?
                .draw(in: shape, angle: 0)
        } else {
            NSGradient(starting: NSColor.systemBlue.withAlphaComponent(0.45), ending: NSColor.systemTeal.withAlphaComponent(0.25))?
                .draw(in: shape, angle: 0)
        }
        let iconRect = NSRect(x: rect.minX + 8, y: rect.midY - 10, width: 20, height: 20)
        if let fan = TBStyle.symbol("fan.fill", size: 15, color: .white) {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: iconRect.midX, yBy: iconRect.midY)
            t.rotate(byDegrees: angle)
            t.translateX(by: -iconRect.midX, yBy: -iconRect.midY)
            t.concat()
            fan.draw(in: iconRect.insetBy(dx: (20 - fan.size.width) / 2, dy: (20 - fan.size.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        TBStyle.draw("\(Int(rpm))", in: NSRect(x: iconRect.maxX + 4, y: rect.minY, width: 46, height: rect.height),
                     font: .monospacedDigitSystemFont(ofSize: 14, weight: .bold), color: .white, align: .left)
        TBStyle.draw(modeLabel.uppercased(), in: NSRect(x: rect.maxX - 44, y: rect.minY, width: 36, height: rect.height),
                     font: .systemFont(ofSize: 9, weight: .heavy), color: NSColor(white: 1, alpha: 0.75), align: .right)
        if !enabledLook {
            NSColor(white: 0, alpha: 0.45).setFill()
            shape.fill()
        }
    }
}

/// On/off capsule. Off: readable white label + tinted outline. On: glowing tinted fill.
/// Unavailable (needs admin mode): padlock, dimmed.
final class TBTogglePill: TBDrawnButton {
    var symbol = "power"
    var label = ""
    var tint: NSColor = .systemGreen
    var isOn = false { didSet { needsDisplay = true } }
    var enabledLook = true { didSet { needsDisplay = true } }

    override func drawContent(_ rect: NSRect) {
        let shape = TBStyle.capsule(rect.insetBy(dx: 1, dy: 1))
        if !enabledLook {
            NSColor(white: 1, alpha: 0.06).setFill()
            shape.fill()
        } else if isOn {
            NSGradient(starting: tint, ending: tint.blended(withFraction: 0.3, of: .black) ?? tint)?.draw(in: shape, angle: -90)
            NSColor(white: 1, alpha: 0.35).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else {
            tint.withAlphaComponent(0.14).setFill()
            shape.fill()
            tint.withAlphaComponent(0.8).setStroke()
            shape.lineWidth = 1.2
            shape.stroke()
        }
        let iconName = enabledLook ? symbol : "lock.fill"
        let iconColor: NSColor = !enabledLook ? TBStyle.dim : isOn ? .white : tint
        let textColor: NSColor = !enabledLook ? TBStyle.dim : .white
        let iconRect = NSRect(x: rect.minX + 10, y: rect.midY - 8, width: 16, height: 16)
        if let icon = TBStyle.symbol(iconName, size: 13, color: iconColor) {
            icon.draw(in: iconRect.insetBy(dx: (16 - icon.size.width) / 2, dy: (16 - icon.size.height) / 2))
        }
        TBStyle.draw(label, in: NSRect(x: iconRect.maxX + 6, y: rect.minY, width: rect.width - iconRect.maxX - 12, height: rect.height),
                     font: .systemFont(ofSize: 12, weight: isOn ? .bold : .semibold), color: textColor, align: .left)
    }
}

/// Icon-only round button for presets.
final class TBIconButton: TBDrawnButton {
    var symbol = "film"
    var tint: NSColor = .systemPurple
    var isActive = false { didSet { needsDisplay = true } }

    override func drawContent(_ rect: NSRect) {
        let shape = TBStyle.capsule(rect.insetBy(dx: 1, dy: 0.75))
        (isActive ? tint.withAlphaComponent(0.85) : TBStyle.idle).setFill()
        shape.fill()
        if let icon = TBStyle.symbol(symbol, size: 13, color: isActive ? .white : tint) {
            let r = NSRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2,
                           width: icon.size.width, height: icon.size.height)
            icon.draw(in: r)
        }
    }
}
