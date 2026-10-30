import AppKit
import CoreText

/// Calculates bounded, wrapping typographic layouts fitting inside wheel petal curves.
public enum WheelSegmentLayout {
    public struct Line {
        public let text: String
        public let run: CTLine
        public var origin: NSPoint
        public var ink: NSRect

        public init(text: String, run: CTLine, origin: NSPoint, ink: NSRect) {
            self.text = text
            self.run = run
            self.origin = origin
            self.ink = ink
        }
    }

    public struct Content {
        public var lines: [Line]
        public var textRect: NSRect
        public var iconRect: NSRect?
        public let color: NSColor
        public let fontSize: CGFloat

        public var bounds: NSRect { iconRect.map { $0.union(textRect) } ?? textRect }
        public var occupiedRects: [NSRect] { lines.map(\.ink) + (iconRect.map { [$0] } ?? []) }

        public func moved(to center: NSPoint) -> Content {
            var copy = self
            let dx = center.x - bounds.midX
            let dy = center.y - bounds.midY
            copy.textRect = textRect.offsetBy(dx: dx, dy: dy)
            copy.iconRect = iconRect?.offsetBy(dx: dx, dy: dy)
            copy.lines = lines.map {
                var line = $0
                line.origin.x += dx
                line.origin.y += dy
                line.ink = line.ink.offsetBy(dx: dx, dy: dy)
                return line
            }
            return copy
        }
    }

    public static func content(
        _ title: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        center: NSPoint,
        iconSize: CGFloat? = nil,
        spacing: CGFloat = 4
    ) -> Content {
        func makeRun(_ str: String) -> CTLine {
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: str,
                    attributes: [
                        .font: font,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]
                )
            )
        }

        var linesText: [String] = []
        for paragraph in title.components(separatedBy: "\n") {
            var currentLine = ""
            for word in paragraph.split(separator: " ") {
                let candidate = currentLine.isEmpty ? String(word) : currentLine + " " + word
                if !currentLine.isEmpty, CTLineGetTypographicBounds(makeRun(candidate), nil, nil, nil) > width {
                    linesText.append(currentLine)
                    currentLine = String(word)
                } else {
                    currentLine = candidate
                }
            }
            linesText.append(currentLine)
        }

        let lineHeight = font.ascender - font.descender + font.leading
        let lines = linesText.enumerated().map { index, string -> Line in
            let line = makeRun(string)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let origin = NSPoint(x: -ink.midX, y: -CGFloat(index) * lineHeight)
            return Line(
                text: string,
                run: line,
                origin: origin,
                ink: ink.offsetBy(dx: origin.x, dy: origin.y)
            )
        }

        let textRect = lines.map(\.ink).reduce(NSRect.null) { $0.union($1) }
        let iconRect = iconSize.map {
            NSRect(x: -$0 / 2, y: textRect.maxY + spacing, width: $0, height: $0)
        }

        return Content(
            lines: lines,
            textRect: textRect,
            iconRect: iconRect,
            color: color,
            fontSize: font.pointSize
        ).moved(to: center)
    }

    public static func fits(_ content: Content, inside path: NSBezierPath, padding: CGFloat) -> Bool {
        content.occupiedRects.allSatisfy { rect in
            let box = rect.insetBy(dx: -padding, dy: -padding)
            return (0...8).allSatisfy { step in
                let t = CGFloat(step) / 8
                return [
                    NSPoint(x: box.minX + box.width * t, y: box.minY),
                    NSPoint(x: box.minX + box.width * t, y: box.maxY),
                    NSPoint(x: box.minX, y: box.minY + box.height * t),
                    NSPoint(x: box.maxX, y: box.minY + box.height * t),
                ].allSatisfy(path.contains)
            }
        }
    }

    public static func fitted(
        _ title: String,
        font: NSFont,
        color: NSColor,
        inside path: NSBezierPath,
        centers: [NSPoint],
        maximumWidth: CGFloat,
        iconSize: CGFloat? = nil,
        scale: CGFloat = 1
    ) -> Content {
        var bestCandidate: Content?

        for reduction in stride(from: CGFloat(0), through: 3 * scale, by: 0.25 * scale) {
            let size = max(6 * scale, font.pointSize - reduction)
            let fittedFont = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            var bestScore = CGFloat.greatestFiniteMagnitude

            for width in stride(from: maximumWidth, through: 36 * scale, by: -4 * scale) {
                let block = content(
                    title,
                    font: fittedFont,
                    color: color,
                    width: width,
                    center: .zero,
                    iconSize: iconSize,
                    spacing: 4 * scale
                )

                for (idx, center) in centers.enumerated() {
                    let placed = block.moved(to: center)
                    guard fits(placed, inside: path, padding: 3.5 * scale) else { continue }
                    if width == maximumWidth, idx == 0 { return placed }
                    let score = CGFloat(block.lines.count) * 10 + CGFloat(idx) + (maximumWidth - width) / maximumWidth
                    if score < bestScore {
                        bestCandidate = placed
                        bestScore = score
                    }
                }
            }
            if let best = bestCandidate { return best }
        }

        return content(
            title,
            font: font,
            color: color,
            width: maximumWidth,
            center: centers[0],
            iconSize: iconSize,
            spacing: 4 * scale
        )
    }

    public static func draw(_ content: Content, color: NSColor? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setFillColor((color ?? content.color).cgColor)
        context.textMatrix = .identity
        for line in content.lines {
            context.textPosition = line.origin
            CTLineDraw(line.run, context)
        }
        context.restoreGState()
    }
}

// Backward-compatibility alias
public typealias WheelLabelLayout = WheelSegmentLayout

