import AppKit

/// Renders the signature Filevero Möbius infinity mark and menu bar glyphs.
public enum ApplicationBrandArtwork {
    public static let gold = NSColor(srgbRed: 0.89, green: 0.72, blue: 0.35, alpha: 1)
    public static let ink = NSColor(srgbRed: 0.20, green: 0.25, blue: 0.14, alpha: 1)

    public static var hasAppIcon: Bool { bundleIcon != nil }

    private static var bundleIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "FileveroIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    public static func draw(in rect: NSRect, happy: Bool = false, monochrome: Bool = false) {
        if !monochrome, let icon = bundleIcon {
            icon.draw(in: rect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: rect.width, y: rect.height)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.13, y: 0.5))
        path.curve(
            to: NSPoint(x: 0.5, y: 0.5),
            controlPoint1: NSPoint(x: 0.13, y: 0.92),
            controlPoint2: NSPoint(x: 0.34, y: 0.88)
        )
        path.curve(
            to: NSPoint(x: 0.87, y: 0.5),
            controlPoint1: NSPoint(x: 0.66, y: 0.12),
            controlPoint2: NSPoint(x: 0.87, y: 0.08)
        )
        path.curve(
            to: NSPoint(x: 0.5, y: 0.5),
            controlPoint1: NSPoint(x: 0.87, y: 0.92),
            controlPoint2: NSPoint(x: 0.66, y: 0.88)
        )
        path.curve(
            to: NSPoint(x: 0.13, y: 0.5),
            controlPoint1: NSPoint(x: 0.34, y: 0.12),
            controlPoint2: NSPoint(x: 0.13, y: 0.08)
        )

        path.lineCapStyle = .round
        path.transform(using: transform)
        path.lineWidth = rect.width * 0.105
        NSColor.black.setStroke()
        path.stroke()
    }

    public static func brandMark(size: CGFloat, happy: Bool = false) -> NSImage {
        if let icon = bundleIcon { return icon }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, happy: happy)
            return true
        }
    }

    public static func menuStatusIcon(updateAvailable: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            draw(in: rect.insetBy(dx: 0.5, dy: 0.5), monochrome: true)
            if updateAvailable {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 15, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = updateAvailable ? "Filevero update available" : "Filevero"
        return image
    }

    // Aliases for backward compatibility
    public static func mark(size: CGFloat, happy: Bool = false) -> NSImage {
        brandMark(size: size, happy: happy)
    }

    public static func menuIcon(updateAvailable: Bool = false) -> NSImage {
        menuStatusIcon(updateAvailable: updateAvailable)
    }
}

// Backward-compatibility alias
public typealias FileveroArtwork = ApplicationBrandArtwork

