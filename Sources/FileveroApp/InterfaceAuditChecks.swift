import AppKit
import FileveroCore
import Foundation
import SwiftUI

/// Quality assurance assertions and layout validator edge cases.
/// Exercises geometry calculations, canvas rasterization, and coordinate containment without launching persistent windows.
@MainActor
public enum InterfaceAuditChecks {
    /// Render the shared redaction canvas (including video and image overlays) to verify opacity and masking integrity.
    public static func redactionPreviews(at output: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checksRecorded: [String] = []

        for colorScheme in [ColorScheme.light, .dark] {
            for isActive in [true, false] {
                for (colorName, chosenColor) in [
                    ("red", Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)),
                    ("blue", Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1))
                ] {
                    let previewView = RasterEditorPreview(
                        image: nil,
                        imageSize: CGSize(width: 64, height: 64),
                        crop: nil,
                        redactions: [EditRect(x: 16, y: 16, width: 32, height: 32)],
                        annotations: [],
                        redactionColor: chosenColor,
                        activeRedactions: isActive ? [0] : []
                    ) { _ in }

                    let previewRenderer = ImageRenderer(
                        content: previewView
                            .frame(width: 64, height: 64)
                            .background(Color.white)
                            .environment(\.colorScheme, colorScheme)
                    )
                    previewRenderer.scale = 1

                    guard let cgImg = previewRenderer.cgImage else {
                        throw InterfaceAuditError("Redaction canvas could not be rendered")
                    }

                    let bitmapRep = NSBitmapImageRep(cgImage: cgImg)
                    guard let centerSample = bitmapRep.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB),
                          let outsideSample = bitmapRep.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)
                    else {
                        throw InterfaceAuditError("Redaction canvas pixels could not be read")
                    }

                    let actualRGB = [centerSample.redComponent, centerSample.greenComponent, centerSample.blueComponent]

                    let referenceRenderer = ImageRenderer(
                        content: (isActive ? chosenColor : Color.white)
                            .frame(width: 64, height: 64)
                            .background(Color.white)
                            .environment(\.colorScheme, colorScheme)
                    )
                    referenceRenderer.scale = 1

                    guard let refImg = referenceRenderer.cgImage,
                          let targetColor = NSBitmapImageRep(cgImage: refImg).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB)
                    else {
                        throw InterfaceAuditError("Opaque color reference could not be rendered")
                    }

                    let expectedRGB = [
                        Double(targetColor.redComponent),
                        Double(targetColor.greenComponent),
                        Double(targetColor.blueComponent)
                    ]

                    let testLabel = "\(colorScheme == .light ? "light" : "dark")-\(isActive ? "active" : "inactive")-\(colorName)"
                    guard let pngBytes = bitmapRep.representation(using: .png, properties: [:]) else {
                        throw InterfaceAuditError("Redaction canvas PNG could not be encoded")
                    }

                    try pngBytes.write(to: output.appendingPathComponent(testLabel + ".png"))

                    guard zip(actualRGB, expectedRGB).allSatisfy({ abs(Double($0.0) - $0.1) < 0.02 }),
                          centerSample.alphaComponent > 0.99,
                          outsideSample.redComponent > 0.99,
                          outsideSample.greenComponent > 0.99,
                          outsideSample.blueComponent > 0.99
                    else {
                        throw InterfaceAuditError(
                            "Redaction canvas \(testLabel): center=\(actualRGB), alpha=\(centerSample.alphaComponent), outside=\([outsideSample.redComponent, outsideSample.greenComponent, outsideSample.blueComponent]), expected=\(expectedRGB)"
                        )
                    }

                    checksRecorded.append("Opaque redaction canvas: " + testLabel)
                }
            }
        }
        return checksRecorded
    }

    @discardableResult
    public static func run() throws -> [String] {
        let referenceBounds = CGRect(x: 0, y: 0, width: 900, height: 420)
        let baselineFrames: [String: CGRect] = [
            "editor.header": CGRect(x: 0, y: 0, width: 900, height: 80),
            "editor.body": CGRect(x: 0, y: 81, width: 900, height: 250),
            "editor.preview": CGRect(x: 0, y: 81, width: 480, height: 250),
            "editor.options": CGRect(x: 481, y: 81, width: 419, height: 250),
            "editor.footer": CGRect(x: 0, y: 332, width: 900, height: 88),
            "editor.reset": CGRect(x: 20, y: 350, width: 100, height: 48),
            "editor.primary": CGRect(x: 600, y: 350, width: 280, height: 48),
            "editor.primary.label": CGRect(x: 620, y: 364, width: 240, height: 20)
        ]

        var recordedChecks: [String] = []

        func assertCheck(_ condition: Bool, _ label: String) throws {
            guard condition else { throw InterfaceAuditError("Layout validator check failed: " + label) }
            recordedChecks.append(label)
        }

        func evaluateIssues(_ delta: [String: CGRect?] = [:], in customBounds: CGRect? = nil) -> [String] {
            let layoutRecorder = InterfaceAuditLayout()
            layoutRecorder.frames = baselineFrames
            for (key, rect) in delta {
                if let rect {
                    layoutRecorder.frames[key] = rect
                } else {
                    layoutRecorder.frames[key] = nil
                }
            }
            return layoutRecorder.issues(in: customBounds ?? referenceBounds, editor: true)
        }

        try assertCheck(evaluateIssues().isEmpty, "Accepts an aligned, contained editor layout")
        try assertCheck(
            evaluateIssues(["editor.options": nil]).contains("Missing layout probe: editor.options"),
            "Rejects a missing required layout probe"
        )
        try assertCheck(
            evaluateIssues(["editor.preview": nil]).contains("Missing layout probe: editor.preview"),
            "Rejects an unmeasured editor preview"
        )
        try assertCheck(
            evaluateIssues(["editor.primary.label": CGRect(x: 630, y: 364, width: 240, height: 20)]).contains(
                "Primary button label is not centered"
            ),
            "Detects a label shifted within a sufficiently large button"
        )
        try assertCheck(
            evaluateIssues(["editor.primary.label": CGRect(x: 590, y: 364, width: 300, height: 20)]).contains(
                "Primary button label is clipped"
            ),
            "Detects centered text that exceeds the button bounds"
        )
        try assertCheck(
            evaluateIssues(["editor.primary": CGRect(x: 100, y: 350, width: 280, height: 48)]).contains(
                "Footer controls overlap"
            ),
            "Detects overlapping footer action targets"
        )
        try assertCheck(
            evaluateIssues(["editor.reset": CGRect(x: 20, y: 300, width: 100, height: 48)]).contains(
                "Footer control is clipped: editor.reset"
            ),
            "Detects a footer control extending into the body"
        )
        try assertCheck(
            evaluateIssues(["editor.options": CGRect(x: 481, y: 70, width: 419, height: 250)]).contains(
                "Body region is clipped: editor.options"
            ),
            "Detects options extending outside their body region"
        )
        try assertCheck(
            evaluateIssues(["editor.body": CGRect(x: 0, y: 70, width: 900, height: 261)]).contains(
                "Body overlaps: editor.header"
            ),
            "Detects body content overlapping the header"
        )
        try assertCheck(
            evaluateIssues(["editor.footer": CGRect(x: 0, y: 322, width: 900, height: 98)]).contains(
                "Body overlaps: editor.footer"
            ),
            "Detects body content overlapping the footer"
        )
        try assertCheck(
            evaluateIssues(["editor.options": CGRect(x: 481, y: 81, width: 430, height: 250)]).contains(
                "Outside visible content: editor.options"
            ),
            "Detects content extending past the visible right edge"
        )
        try assertCheck(
            evaluateIssues(["editor.options": CGRect(x: 481, y: 81, width: 0, height: 250)]).contains(
                "Invalid layout frame: editor.options"
            ),
            "Rejects a zero-sized layout frame"
        )
        try assertCheck(
            evaluateIssues(["editor.options": CGRect(x: 481, y: 81, width: Double.nan, height: 250)]).contains(
                "Invalid layout frame: editor.options"
            ),
            "Rejects non-finite geometry"
        )
        try assertCheck(
            evaluateIssues(in: .zero) == ["Invalid visible content bounds"],
            "Rejects a zero-sized visible surface"
        )

        let emptyRecorder = InterfaceAuditLayout()
        try assertCheck(
            emptyRecorder.issues(in: referenceBounds, editor: true).count == baselineFrames.count,
            "An empty editor measurement cannot pass"
        )

        var pixelStorage = [UInt8](repeating: 0, count: 64 * 64 * 4)
        func inspectSyntheticRaster() throws -> InterfaceAuditRaster {
            let dataProvider = CGDataProvider(data: Data(pixelStorage) as CFData)!
            guard let syntheticImage = CGImage(
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: dataProvider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else {
                throw InterfaceAuditError("Raster validator fixture allocation failed")
            }
            return InterfaceAuditRaster.inspect(NSBitmapImageRep(cgImage: syntheticImage))
        }

        try assertCheck(!inspectSyntheticRaster().nonBlank, "Rejects a fully transparent scene capture")

        for offset in stride(from: 0, to: pixelStorage.count, by: 4) {
            pixelStorage[offset] = 128
            pixelStorage[offset + 1] = 128
            pixelStorage[offset + 2] = 128
            pixelStorage[offset + 3] = 255
        }
        try assertCheck(!inspectSyntheticRaster().nonBlank, "Rejects a uniform scene capture")

        for y in 0..<64 {
            for x in 0..<64 {
                let offset = (y * 64 + x) * 4
                pixelStorage[offset] = x < 21 ? 255 : 0
                pixelStorage[offset + 1] = (21..<42).contains(x) ? 255 : 0
                pixelStorage[offset + 2] = x >= 42 ? 255 : 0
            }
        }
        let dynamicRaster = try inspectSyntheticRaster()
        try assertCheck(
            dynamicRaster.nonBlank && dynamicRaster.samples == 4096 && dynamicRaster.colors == 3,
            "Accepts a visible scene with sampled color variation"
        )

        return recordedChecks
    }
}

// MARK: - Backwards Compatibility Bridge
public typealias UIAuditChecks = InterfaceAuditChecks

