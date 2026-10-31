import AppKit

// Draws the disk image window background at 1x and 2x. Finder places the icons on top of it, so the arrow and
// texts below must match the icon positions in scripts/dmg-settings.py (top-left origin, 640 × 500 points). The window frame
// also holds the title bar and, when the user shows it, Finder's path bar, so everything stays above y = 420.
enum MakeDMGBackground {
    static let size = NSSize(width: 640, height: 500)
    static let ink = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1)
    static let secondaryInk = NSColor(srgbRed: 0.33, green: 0.35, blue: 0.47, alpha: 1)
    static let blue = NSColor(srgbRed: 0.23, green: 0.42, blue: 0.96, alpha: 1)
    static let violet = NSColor(srgbRed: 0.48, green: 0.31, blue: 0.88, alpha: 1)

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["notarized", "unnotarized"].contains(arguments[2]) else {
            FileHandle.standardError.write(Data("Usage: make-dmg-background.swift OUTPUT_DIR notarized|unnotarized\n".utf8))
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let name = scale == 1 ? "background.png" : "background@2x.png"
            try render(scale: scale, notarized: arguments[2] == "notarized").write(to: output.appendingPathComponent(name))
        }
    }

    static func render(scale: Int, notarized: Bool) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        // Draw in points with Finder's top-left origin; text draws upright because the context is marked flipped.
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        context.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawBackground()
        drawHeading()
        drawArrow(from: NSPoint(x: 252, y: 206), to: NSPoint(x: 388, y: 206))
        drawFooter(notarized: notarized)
        NSGraphicsContext.restoreGraphicsState()
        // Records 144 dpi in the 2x file so the combined TIFF keeps both resolutions at the same point size.
        rep.size = size
        return rep.representation(using: .png, properties: [:])!
    }

    static func drawBackground() {
        NSGradient(
            starting: NSColor(srgbRed: 0.968, green: 0.964, blue: 0.992, alpha: 1),
            ending: NSColor(srgbRed: 0.905, green: 0.922, blue: 0.985, alpha: 1)
        )!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        for (center, color) in [(NSPoint(x: 170, y: 206), blue), (NSPoint(x: 470, y: 206), violet)] {
            NSGradient(starting: color.withAlphaComponent(0.16), ending: color.withAlphaComponent(0))!
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: 120, options: [])
        }
    }

    static func drawHeading() {
        text("Install Filevero", font: .systemFont(ofSize: 24, weight: .bold), color: ink, top: 36)
        text("Drag Filevero onto the Applications folder.", font: .systemFont(ofSize: 14, weight: .medium), color: ink, top: 72)
        text("Filevero’yu Uygulamalar klasörünün üzerine sürükle.", font: .systemFont(ofSize: 13), color: secondaryInk, top: 94)
    }

    static func drawArrow(from start: NSPoint, to end: NSPoint) {
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.curve(
            to: NSPoint(x: end.x - 14, y: end.y),
            controlPoint1: NSPoint(x: start.x + 40, y: start.y - 26),
            controlPoint2: NSPoint(x: end.x - 54, y: end.y - 26))
        shaft.lineWidth = 5
        shaft.lineCapStyle = .round
        shaft.setLineDash([1, 11], count: 2, phase: 0)
        let head = NSBezierPath()
        head.move(to: NSPoint(x: end.x - 18, y: end.y - 12))
        head.line(to: end)
        head.line(to: NSPoint(x: end.x - 20, y: end.y + 9))
        head.lineWidth = 5
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        // Stroke through a gradient mask so the arrow runs from the app's blue to the folder's violet.
        let bounds = shaft.bounds.union(head.bounds).insetBy(dx: -8, dy: -8)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current!.cgContext
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.black.setStroke()
        shaft.stroke()
        head.stroke()
        context.setBlendMode(.sourceIn)
        NSGradient(starting: blue, ending: violet)!.draw(in: bounds, angle: 0)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawFooter(notarized: Bool) {
        let card = NSRect(x: 40, y: 324, width: 560, height: 92)
        let path = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor(srgbRed: 0.42, green: 0.40, blue: 0.80, alpha: 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
        let lines: [(String, String)] = notarized
            ? [("After copying, open Filevero from Applications and eject this disk.",
                "Kopyaladıktan sonra Filevero’yu Uygulamalar’dan aç ve bu diski çıkar.")]
            : [("First launch: Filevero is not notarized by Apple yet. If macOS blocks it, open System Settings → Privacy & Security and choose Open Anyway.",
                "İlk açılış: Filevero henüz Apple tarafından notarize edilmedi. macOS engellerse Sistem Ayarları → Gizlilik ve Güvenlik’te Yine de Aç’ı seç.")]
        let inner = card.insetBy(dx: 22, dy: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let english = NSAttributedString(string: lines[0].0, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ink, .paragraphStyle: paragraph,
        ])
        let turkish = NSAttributedString(string: lines[0].1, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: secondaryInk, .paragraphStyle: paragraph,
        ])
        let first = english.boundingRect(with: inner.size, options: [.usesLineFragmentOrigin]).height
        let second = turkish.boundingRect(with: inner.size, options: [.usesLineFragmentOrigin]).height
        var top = inner.minY + (inner.height - first - second - 6) / 2
        english.draw(with: NSRect(x: inner.minX, y: top, width: inner.width, height: first), options: [.usesLineFragmentOrigin])
        top += first + 6
        turkish.draw(with: NSRect(x: inner.minX, y: top, width: inner.width, height: second), options: [.usesLineFragmentOrigin])
    }

    static func text(_ string: String, font: NSFont, color: NSColor, top: CGFloat) {
        let value = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let width = value.size().width
        value.draw(at: NSPoint(x: (size.width - width) / 2, y: top))
    }
}

try MakeDMGBackground.main()
