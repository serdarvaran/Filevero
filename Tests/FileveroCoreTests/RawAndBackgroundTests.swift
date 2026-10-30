import XCTest
@testable import FileveroCore

final class RawAndBackgroundTests: XCTestCase {
    func testRawFormatsRegisteredInImageCategory() {
        let rawExts = ["dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"]
        for ext in rawExts {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertEqual(FileCategory.detect(url), .image, "Extension \(ext) must be recognized as .image")
        }
    }

    func testRawFormatsHaveConversionRoutes() {
        let rawExts = ["dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"]
        for ext in rawExts {
            let targets = CapabilityCatalog.allConversions[ext]
            XCTAssertNotNil(targets, "\(ext) must have conversion targets")
            XCTAssertTrue(targets?.contains("jpg") == true)
            XCTAssertTrue(targets?.contains("png") == true)
            XCTAssertTrue(targets?.contains("pdf") == true)
        }
    }

    func testRawFormatsSupportSingleAndMultipleTools() {
        let rawExts = ["dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"]
        for ext in rawExts {
            let single = CapabilityCatalog.macOnlySingleTools[ext]
            XCTAssertNotNil(single, "\(ext) should have single tools")
            XCTAssertTrue(single?.contains(.removeBackground) == true)
            XCTAssertTrue(single?.contains(.compress) == true)

            let multiple = CapabilityCatalog.macOnlyMultipleTools[ext]
            XCTAssertNotNil(multiple, "\(ext) should have multiple tools")
            XCTAssertTrue(multiple?.contains(.createPDF) == true)
        }
    }

    func testCameraRawEditsAreSavedInAWritableFormat() throws {
        let directory = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let png = directory.appendingPathComponent("Source.png")
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: png)
        // ImageIO identifies the content by its signature, so PNG bytes stand in for a camera file here.
        let raw = directory.appendingPathComponent("Camera.dng")
        try FileManager.default.moveItem(at: png, to: raw)

        for kind: ToolKind in [.editImage, .cropImage, .frameImage, .redactImage] {
            var options = OperationOptions()
            options.outputDirectory = directory
            options.crop = EditRect(x: 0, y: 0, width: 32, height: 32)
            options.redactions = [EditRect(x: 0, y: 0, width: 8, height: 8)]
            let outputs = try ImageEngine.tool(kind, inputs: [raw], options: options, token: CancellationToken())
            XCTAssertEqual(outputs.map { $0.pathExtension }, ["jpg"], "\(kind)")
        }
        guard case .convert(let format) = WorkflowStep.resize(maxDimension: 16).request(for: [raw], into: directory).operation
        else { return XCTFail("Resizing should convert") }
        XCTAssertEqual(format, "jpg")
    }

    func testRemoveBackgroundToolMetadata() {
        let kind = ToolKind.removeBackground
        XCTAssertEqual(kind.rawValue, "removeBackground")
        XCTAssertEqual(kind.title, "Remove Background")
        XCTAssertEqual(CapabilityCatalog.toolNames[kind], "Remove Background")
        XCTAssertTrue(CapabilityCatalog.singleTools["png"]?.contains(kind) == true, "Windows removes backgrounds too")
        XCTAssertTrue(CapabilityCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.png")]).contains(kind))
        XCTAssertEqual(CapabilityCatalog.toolSymbols[kind], "wand.and.stars")
        XCTAssertEqual(kind.editorHint?.isEmpty, false)
        XCTAssertEqual(kind.saveTitle?.isEmpty, false)
    }

    func testSocialMediaPresetsFitCalculation() {
        let presets = SocialMediaPreset.standardPresets
        XCTAssertFalse(presets.isEmpty)

        let squarePreset = presets.first { $0.id == "ig-square" }!
        let sourceSize = CGSize(width: 2000, height: 1000)
        let crop = squarePreset.fit(in: sourceSize)

        XCTAssertEqual(crop.width, 1000, accuracy: 0.001)
        XCTAssertEqual(crop.height, 1000, accuracy: 0.001)
        XCTAssertEqual(crop.x, 500, accuracy: 0.001)
        XCTAssertEqual(crop.y, 0, accuracy: 0.001)
    }
}
