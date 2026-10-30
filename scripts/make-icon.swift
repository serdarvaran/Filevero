import AppKit

@main struct MakeFileveroIcon {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func bitmap(_ width: Int, _ height: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        guard let source = NSImage(contentsOfFile: "Resources/Brand/FileveroIcon.png") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let icon = bitmap(1024, 1024) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect)
        }
        let png = icon.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent("FileveroIcon.png"))
        let iconset = output.appendingPathComponent("FileveroIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let image = NSImage(data: png)!
        for size in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let pixels = size * factor
                let rep = bitmap(pixels, pixels) { rect in
                    NSGraphicsContext.current?.imageInterpolation = .high
                    image.draw(in: rect)
                }
                try rep.representation(using: .png, properties: [:])!.write(
                    to: iconset.appendingPathComponent("icon_\(size)x\(size)\(factor==2 ? "@2x":"").png"))
            }
        }
        let banner = bitmap(1280, 640) { rect in
            NSColor(srgbRed: 0.976, green: 0.965, blue: 0.930, alpha: 1).setFill()
            rect.fill()
            source.draw(in: NSRect(x: 75, y: 115, width: 390, height: 410))
            let font = NSFont.systemFont(ofSize: 118, weight: .bold)
            let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded)!, size: 118)!
            ("Filevero" as NSString).draw(
                at: NSPoint(x: 515, y: 315),
                withAttributes: [
                    .font: rounded, .foregroundColor: NSColor(srgbRed: 0.17, green: 0.27, blue: 0.19, alpha: 1),
                ])
            ("Your files, in flow." as NSString).draw(
                at: NSPoint(x: 523, y: 265),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 32, weight: .medium),
                    .foregroundColor: NSColor(srgbRed: 0.30, green: 0.40, blue: 0.29, alpha: 1),
                ])
            ("Convert. Edit. Organize. Download." as NSString).draw(
                at: NSPoint(x: 523, y: 208),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 23),
                    .foregroundColor: NSColor(srgbRed: 0.43, green: 0.47, blue: 0.39, alpha: 1),
                ])
        }
        try banner.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("FileveroSocial.png"))
        print(output.path)
    }
}
