import AppKit
import SwiftUI

// MARK: - Interface Audit Layout & Geometry Probe Engine

private struct InterfaceAuditEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var uiAuditEnabled: Bool {
        get { self[InterfaceAuditEnabledKey.self] }
        set { self[InterfaceAuditEnabledKey.self] = newValue }
    }
}

private struct InterfaceAuditFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct InterfaceAuditStatusKey: PreferenceKey {
    static let defaultValue = "ready"
    static func reduce(value: inout String, nextValue: () -> String) {
        value = nextValue()
    }
}

private struct InterfaceAuditProbeModifier: ViewModifier {
    @Environment(\.uiAuditEnabled) private var enabled
    let identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: InterfaceAuditFramesKey.self,
                        value: [identifier: proxy.frame(in: .named("filevero.ui-audit"))]
                    )
                }
            )
        } else {
            content
        }
    }
}

private struct InterfaceAuditStatusModifier: ViewModifier {
    @Environment(\.uiAuditEnabled) private var enabled
    let value: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.preference(key: InterfaceAuditStatusKey.self, value: value)
        } else {
            content
        }
    }
}

@MainActor
public final class InterfaceAuditLayout {
    public var frames: [String: CGRect] = [:]
    public var status = "waiting"

    public init() {}

    /// Form-only workbench editors (such as OCR) omit the preview pane column.
    public func issues(in bounds: CGRect, editor: Bool, preview: Bool = true) -> [String] {
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              bounds.width > 0,
              bounds.height > 0
        else {
            return ["Invalid visible content bounds"]
        }

        var detectedIssues: [String] = []
        let tolerance: CGFloat = 1
        let outerVisibleRect = bounds.insetBy(dx: -tolerance, dy: -tolerance)

        if editor {
            for probeName in [
                "editor.header", "editor.body", "editor.preview", "editor.options", "editor.footer",
                "editor.primary", "editor.primary.label", "editor.reset"
            ] where frames[probeName] == nil && (preview || probeName != "editor.preview") {
                detectedIssues.append("Missing layout probe: " + probeName)
            }
        }

        for (probeName, rect) in frames {
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
                  rect.width > 0,
                  rect.height > 0
            else {
                detectedIssues.append("Invalid layout frame: " + probeName)
                continue
            }
            if !outerVisibleRect.contains(rect) {
                detectedIssues.append("Outside visible content: " + probeName)
            }
        }

        if let footerRect = frames["editor.footer"] {
            for probeName in ["editor.primary", "editor.reset"] {
                if let itemRect = frames[probeName], !footerRect.insetBy(dx: -1, dy: -1).contains(itemRect) {
                    detectedIssues.append("Footer control is clipped: " + probeName)
                }
            }
        }

        if let buttonRect = frames["editor.primary"], let labelRect = frames["editor.primary.label"] {
            if abs(buttonRect.midX - labelRect.midX) > 1 || abs(buttonRect.midY - labelRect.midY) > 1 {
                detectedIssues.append("Primary button label is not centered")
            }
            if !buttonRect.insetBy(dx: -1, dy: -1).contains(labelRect) {
                detectedIssues.append("Primary button label is clipped")
            }
        }

        if let primaryRect = frames["editor.primary"], let resetRect = frames["editor.reset"], primaryRect.intersects(resetRect) {
            detectedIssues.append("Footer controls overlap")
        }

        if let headerRect = frames["editor.header"], let footerRect = frames["editor.footer"], headerRect.intersects(footerRect) {
            detectedIssues.append("Header and footer overlap")
        }

        if let bodyRect = frames["editor.body"] {
            for probeName in ["editor.preview", "editor.options"] {
                if let itemRect = frames[probeName], !bodyRect.insetBy(dx: -tolerance, dy: -tolerance).contains(itemRect) {
                    detectedIssues.append("Body region is clipped: " + probeName)
                }
            }
            for probeName in ["editor.header", "editor.footer"] {
                if let itemRect = frames[probeName], bodyRect.intersects(itemRect) {
                    detectedIssues.append("Body overlaps: " + probeName)
                }
            }
        }

        return detectedIssues.sorted()
    }

    public var jsonFrames: [String: [String: Double]] {
        frames.mapValues { rect in
            [
                "x": rect.minX,
                "y": rect.minY,
                "width": rect.width,
                "height": rect.height
            ].mapValues { $0.isFinite ? Double($0) : 0 }
        }
    }
}

extension View {
    public func uiAuditProbe(_ id: String) -> some View {
        modifier(InterfaceAuditProbeModifier(identifier: id))
    }

    public func uiAuditStatus(_ value: String) -> some View {
        modifier(InterfaceAuditStatusModifier(value: value))
    }

    @MainActor
    public func uiAuditRoot(_ recorder: InterfaceAuditLayout) -> some View {
        self.environment(\.uiAuditEnabled, true)
            .coordinateSpace(name: "filevero.ui-audit")
            .onPreferenceChange(InterfaceAuditFramesKey.self) { recorder.frames = $0 }
            .onPreferenceChange(InterfaceAuditStatusKey.self) { recorder.status = $0 }
    }
}

// MARK: - Interface Audit Raster Inspection

public struct InterfaceAuditRaster {
    public let samples: Int
    public let visibleSamples: Int
    public let colors: Int

    public var nonBlank: Bool {
        visibleSamples > 100 && colors >= 3
    }

    public static func inspect(_ bitmap: NSBitmapImageRep) -> Self {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0, let cgImg = bitmap.cgImage else {
            return Self(samples: 0, visibleSamples: 0, colors: 0)
        }

        let columns = min(64, width)
        let rows = min(64, height)
        var pixelBuffer = [UInt8](repeating: 0, count: columns * rows * 4)

        let success = pixelBuffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cgImg, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }

        guard success else {
            return Self(samples: 0, visibleSamples: 0, colors: 0)
        }

        var visibleCount = 0
        var distinctColors = Set<UInt32>()

        for offset in stride(from: 0, to: pixelBuffer.count, by: 4) where pixelBuffer[offset + 3] > 0 {
            visibleCount += 1
            if distinctColors.count < 64 {
                let colorKey = UInt32(pixelBuffer[offset]) |
                    (UInt32(pixelBuffer[offset + 1]) << 8) |
                    (UInt32(pixelBuffer[offset + 2]) << 16) |
                    (UInt32(pixelBuffer[offset + 3]) << 24)
                distinctColors.insert(colorKey)
            }
        }

        return Self(samples: columns * rows, visibleSamples: visibleCount, colors: distinctColors.count)
    }
}

// MARK: - Backwards Compatibility Bridges
public struct InterfaceAuditError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public typealias UIAuditError = InterfaceAuditError
public typealias UIAuditLayout = InterfaceAuditLayout
public typealias UIAuditRaster = InterfaceAuditRaster
