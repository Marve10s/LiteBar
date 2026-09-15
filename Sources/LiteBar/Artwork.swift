import AppKit
import SwiftUI

enum Status {
    static func color(leftFraction: Double, hasError: Bool = false) -> NSColor {
        if hasError { return .systemGray }
        switch leftFraction {
        case 0.5...: return .systemGreen
        case 0.2..<0.5: return .systemOrange
        default: return .systemRed
        }
    }

    static func swiftUIColor(leftFraction: Double) -> Color {
        Color(nsColor: color(leftFraction: leftFraction))
    }
}

enum Gauge {
    static let startAngle: CGFloat = 225
    static let sweep: CGFloat = 270

    static func arc(center: CGPoint, radius: CGFloat, fraction: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let clamped = max(0.001, min(1, fraction))
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle - sweep * clamped,
            clockwise: true
        )
        path.lineCapStyle = .round
        return path
    }

    static func bolt(center: CGPoint, height: CGFloat) -> NSBezierPath {
        let points: [CGPoint] = [
            CGPoint(x: 0.58, y: 1.00),
            CGPoint(x: 0.12, y: 0.42),
            CGPoint(x: 0.46, y: 0.42),
            CGPoint(x: 0.38, y: 0.00),
            CGPoint(x: 0.88, y: 0.58),
            CGPoint(x: 0.54, y: 0.58),
        ]
        let width = height * 0.62
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        let path = NSBezierPath()
        for (index, unit) in points.enumerated() {
            let point = CGPoint(x: origin.x + unit.x * width, y: origin.y + unit.y * height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}

enum MenuBarGlyph {
    static func image(leftFraction: Double, hasError: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY - 0.5)
            let radius: CGFloat = 6.2
            let lineWidth: CGFloat = 2.7

            let track = Gauge.arc(center: center, radius: radius, fraction: 1)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()

            let fill = Gauge.arc(center: center, radius: radius, fraction: hasError ? 1 : leftFraction)
            fill.lineWidth = lineWidth
            Status.color(leftFraction: leftFraction, hasError: hasError).setStroke()
            fill.stroke()

            if hasError {
                NSColor.labelColor.withAlphaComponent(0.7).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum AppIconArtwork {
    static func draw(in rect: NSRect, framed: Bool = true) {
        let tileRect = framed ? rect.insetBy(dx: rect.width * 100 / 1024, dy: rect.height * 100 / 1024) : rect
        let scale = min(tileRect.width, tileRect.height) / 824
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY - 10 * scale)

        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185 * scale, yRadius: 185 * scale)
        if framed {
            NSGraphicsContext.saveGraphicsState()
            let tileShadow = NSShadow()
            tileShadow.shadowBlurRadius = 24 * scale
            tileShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
            tileShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
            tileShadow.set()
            NSColor.black.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(
            starting: NSColor(srgbRed: 0x14 / 255, green: 0x17 / 255, blue: 0x1E / 255, alpha: 1),
            ending: NSColor(srgbRed: 0x2E / 255, green: 0x34 / 255, blue: 0x40 / 255, alpha: 1)
        )?.draw(in: tile, angle: 90)

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(colors: [
            NSColor(calibratedWhite: 1, alpha: 0.10),
            NSColor(calibratedWhite: 1, alpha: 0),
        ])?.draw(
            fromCenter: CGPoint(x: tileRect.midX, y: tileRect.maxY),
            radius: 0,
            toCenter: CGPoint(x: tileRect.midX, y: tileRect.maxY),
            radius: 760 * scale,
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        let radius = 236 * scale
        let lineWidth = 80 * scale
        let track = Gauge.arc(center: center, radius: radius, fraction: 1)
        track.lineWidth = lineWidth
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        track.stroke()

        let fill = Gauge.arc(center: center, radius: radius, fraction: 0.72)
        let stroked = fill.cgPath.copy(
            strokingWithWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.shadowColor = NSColor(srgbRed: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 0.35)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(cgPath: stroked).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(cgPath: stroked).addClip()
        NSGradient(
            starting: NSColor(srgbRed: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255, alpha: 1),
            ending: NSColor(srgbRed: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1)
        )?.draw(in: tileRect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        let boltShadow = NSShadow()
        boltShadow.shadowBlurRadius = 16 * scale
        boltShadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
        boltShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
        boltShadow.set()
        NSColor.white.setFill()
        Gauge.bolt(center: CGPoint(x: center.x, y: center.y + 8 * scale), height: 244 * scale).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func headerImage(size: CGFloat = 20) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, framed: false)
            return true
        }
    }
}

@MainActor
enum BrandIcon {
    private static var templates: [String: NSImage] = [:]
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("LiteBar_LiteBar.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    static func tint(for provider: Provider) -> NSColor {
        switch provider {
        case .codex: NSColor(srgbRed: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255, alpha: 1)
        case .claude: NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .antigravity: NSColor(srgbRed: 0x4C / 255, green: 0x8D / 255, blue: 0xF5 / 255, alpha: 1)
        case .opencode: NSColor.labelColor
        }
    }

    private static func template(_ provider: Provider) -> NSImage? {
        if let cached = templates[provider.rawValue] { return cached }
        let name: String = switch provider {
        case .codex: "openai"
        case .claude: "claude"
        case .antigravity: "antigravity"
        case .opencode: "opencode"
        }
        guard let url = resources.url(forResource: name, withExtension: "svg", subdirectory: "icons/brand"),
              let image = NSImage(contentsOf: url) else { return nil }
        templates[provider.rawValue] = image
        return image
    }

    static func providerIcon(_ provider: Provider, size: CGFloat = 16) -> NSImage? {
        guard let template = template(provider) else { return nil }
        let tint = tint(for: provider)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            template.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
