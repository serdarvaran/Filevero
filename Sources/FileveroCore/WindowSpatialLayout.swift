import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Commands for window geometry repositioning across multiple attached displays or restoring prior states.
public enum WindowCommand: String, Sendable, CaseIterable {
    case restore, nextDisplay
    
    public var title: String {
        self == .restore ? "Previous position" : "Next display"
    }
    
    public var symbol: String {
        self == .restore ? "arrow.uturn.backward" : "rectangle.on.rectangle"
    }
}

/// Geometric coordinate transforms for window placement across single or multi-monitor display workspaces.
public enum WindowGeometry {
    
    /// Translates a frame proportionally from a source display work area to a target display work area.
    public static func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return frame }
        let scaledWidth = min(target.width, frame.width * target.width / source.width)
        let scaledHeight = min(target.height, frame.height * target.height / source.height)
        let mappedX = target.minX + (frame.minX - source.minX) / source.width * target.width
        let mappedY = target.minY + (frame.minY - source.minY) / source.height * target.height
        return clampWithin(CGRect(x: mappedX, y: mappedY, width: scaledWidth, height: scaledHeight), in: target)
    }

    /// Selects the next monitor in natural reading order (left-to-right, top-to-bottom), wrapping around.
    public static func display(after current: CGRect, in displays: [CGRect]) -> CGRect? {
        let sortedDisplays = displays.sorted { $0.minX != $1.minX ? $0.minX < $1.minX : $0.maxY > $1.maxY }
        guard sortedDisplays.count > 1, let currentIndex = sortedDisplays.firstIndex(of: current) else { return nil }
        return sortedDisplays[(currentIndex + 1) % sortedDisplays.count]
    }

    /// Resolves the display containing the frame's midpoint, or the one with maximal surface intersection.
    public static func display(for frame: CGRect, in displays: [CGRect]) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let directHit = displays.first(where: { $0.contains(center) }) {
            return directHit
        }
        return displays.max { computeOverlap(frame, $0) < computeOverlap(frame, $1) }
    }

    /// Constrains a previously saved frame to available active displays, ensuring visibility on reconnection.
    public static func clamp(_ frame: CGRect, to displays: [CGRect]) -> CGRect {
        guard let targetDisplay = display(for: frame, in: displays) else { return frame }
        let activeDisplay = targetDisplay.contains(CGPoint(x: frame.midX, y: frame.midY)) || computeOverlap(frame, targetDisplay) > 0
            ? targetDisplay
            : displays[0]
            
        return clampWithin(
            CGRect(
                origin: frame.origin,
                size: CGSize(width: min(frame.width, activeDisplay.width), height: min(frame.height, activeDisplay.height))
            ),
            in: activeDisplay
        )
    }

    private static func clampWithin(_ frame: CGRect, in boundary: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, boundary.minX), boundary.maxX - frame.width),
            y: min(max(frame.minY, boundary.minY), boundary.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func computeOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

/// Standardized fractional partition placements for snapping windows to grid coordinates.
public enum WindowPlacement: String, CaseIterable, Sendable, Codable {
    case leftThird, middleThird, rightThird, leftHalf, rightHalf, leftTwoThirds, rightTwoThirds, maximize, topHalf,
        bottomHalf, topLeft, topRight, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .leftThird: return "Left third"
        case .middleThird: return "Middle third"
        case .rightThird: return "Right third"
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .leftTwoThirds: return "Left two-thirds"
        case .rightTwoThirds: return "Right two-thirds"
        case .maximize: return "Maximize"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    public var fraction: String {
        switch self {
        case .leftThird, .middleThird, .rightThird: return "1/3"
        case .leftHalf, .rightHalf: return "1/2"
        case .leftTwoThirds, .rightTwoThirds: return "2/3"
        case .maximize: return "100%"
        case .topHalf, .bottomHalf: return "1/2"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "1/4"
        }
    }

    public var horizontalRange: ClosedRange<Double> {
        switch self {
        case .leftThird: return 0...(1.0 / 3)
        case .middleThird: return (1.0 / 3)...(2.0 / 3)
        case .rightThird: return (2.0 / 3)...1
        case .leftHalf: return 0...0.5
        case .rightHalf: return 0.5...1
        case .leftTwoThirds: return 0...(2.0 / 3)
        case .rightTwoThirds: return (1.0 / 3)...1
        case .maximize, .topHalf, .bottomHalf: return 0...1
        case .topLeft, .bottomLeft: return 0...0.5
        case .topRight, .bottomRight: return 0.5...1
        }
    }

    public var verticalRange: ClosedRange<Double> {
        switch self {
        case .topHalf, .topLeft, .topRight: return 0.5...1
        case .bottomHalf, .bottomLeft, .bottomRight: return 0...0.5
        default: return 0...1
        }
    }

    public func frame(in workArea: CGRect, scale: CGFloat = 1, minimumSize: CGSize = .zero) -> CGRect {
        guard workArea.width > 0, workArea.height > 0, workArea.width.isFinite, workArea.height.isFinite,
              workArea.origin.x.isFinite, workArea.origin.y.isFinite
        else { return .zero }
        
        if self == .maximize { return workArea }
        let pixelScale = scale.isFinite && scale > 0 ? scale : 1.0
        
        func calculateAxis(origin: CGFloat, length: CGFloat, range: ClosedRange<Double>, minimum: CGFloat) -> (CGFloat, CGFloat) {
            let start = (length * range.lowerBound * pixelScale).rounded() / pixelScale
            let end = (length * range.upperBound * pixelScale).rounded() / pixelScale
            let requested = end - start
            let safeMin = minimum.isFinite ? max(0, minimum) : 0
            guard safeMin > requested else { return (origin + start, requested) }
            let size = min(length, max(requested, safeMin))
            let position = range.lowerBound == 0
                ? origin
                : range.upperBound == 1 ? origin + length - size : origin + (length - size) / 2.0
            return (position, size)
        }
        
        let x = calculateAxis(origin: workArea.minX, length: workArea.width, range: horizontalRange, minimum: minimumSize.width)
        let y = calculateAxis(origin: workArea.minY, length: workArea.height, range: verticalRange, minimum: minimumSize.height)
        return CGRect(x: x.0, y: y.0, width: x.1, height: y.1)
    }
}

/// Differentiates intentional window frame dragging from file or text payload drag gestures.
public struct WindowDragIntent: Sendable {
    public private(set) var cancelled = false

    public init() {}

    public mutating func cancel() {
        cancelled = true
    }

    public mutating func accepts(
        pointerDistance: Double,
        frameChanged: Bool,
        freshFileDrag: Bool,
        requested: Bool
    ) -> Bool {
        if freshFileDrag { cancelled = true }
        return !cancelled && frameChanged && pointerDistance > 4.0 && requested
    }
}

/// A named, saved multi-window desktop arrangement across applications.
public struct WindowLayout: Codable, Identifiable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let bundleID: String
        public let title: String
        public let frame: CGRect
        
        public init(bundleID: String, title: String, frame: CGRect) {
            self.bundleID = bundleID
            self.title = title
            self.frame = frame
        }
    }
    
    public var id = UUID()
    public var name: String
    public var windows: [Window]
    
    public init(name: String, windows: [Window]) {
        self.name = name
        self.windows = windows
    }

    /// Maps active windows to saved target coordinates based on bundle identifier and window title matching.
    public func assignments(for open: [(bundleID: String, title: String)]) -> [Int: Window] {
        var result: [Int: Window] = [:]
        var usedIndices = Set<Int>()
        
        for (index, window) in open.enumerated() {
            if let matched = windows.indices.first(where: {
                !usedIndices.contains($0)
                    && windows[$0].bundleID == window.bundleID
                    && windows[$0].title == window.title
                    && !window.title.isEmpty
            }) {
                result[index] = windows[matched]
                usedIndices.insert(matched)
            }
        }
        
        for (index, window) in open.enumerated() where result[index] == nil {
            if let matched = windows.indices.first(where: {
                !usedIndices.contains($0) && windows[$0].bundleID == window.bundleID
            }) {
                result[index] = windows[matched]
                usedIndices.insert(matched)
            }
        }
        
        return result
    }
}

