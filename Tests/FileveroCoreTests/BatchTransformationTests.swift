import ImageIO
import PDFKit
import XCTest

@testable import FileveroCore

final class BatchToolsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func image(
        _ name: String, width: Int = 400, height: Int = 200, gray: CGFloat = 0.2, properties: [CFString: Any] = [:]
    ) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let type = url.pathExtension == "png" ? "public.png" : "public.jpeg"
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func pdf(_ name: String, pages: Int = 3, text: String = "Page") throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0..<pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "\(text) \(page+1)",
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                            "Helvetica" as CFString, 18, nil)
                    ]))
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func run(_ tool: ToolKind, _ inputs: [URL], configure: (inout OperationOptions) -> Void = { _ in }) throws
        -> [URL]
    {
        var options = OperationOptions()
        options.revealInFinder = false
        configure(&options)
        return try ConversionEngine.run(ConversionRequest(inputs: inputs, operation: .tool(tool), options: options))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    func testImageToolsAreOfferedForTheRightSelections() throws {
        let photo = try image("a.jpg")
        let second = try image("b.png")
        let report = try pdf("doc.pdf")
        let images = FeatureCatalog.tools(for: [photo, second])
        XCTAssertTrue(
            images.contains(.watermark) && images.contains(.uniformSize) && images.contains(.createAnimation)
                && images.contains(.removeLocation))
        XCTAssertFalse(images.contains(.combineToPDF))
        let pdfs = FeatureCatalog.tools(for: [report])
        XCTAssertTrue(pdfs.contains(.pageNumbers) && pdfs.contains(.protectPDF) && pdfs.contains(.unlockPDF))
        XCTAssertTrue(FeatureCatalog.tools(for: [photo, report]).contains(.combineToPDF))
        XCTAssertTrue(FeatureCatalog.tools(for: [photo, report]).contains(.watermark))
    }

    func testWatermarkDrawsOnlyWhereItIsPlaced() throws {
        let source = try image("photo.jpg", width: 800, height: 400, gray: 0.1)
        let output = try run(.watermark, [source]) {
            var mark = WatermarkOptions()
            mark.text = "FILEVERO"
            mark.opacity = 1
            mark.position = .bottomRight
            $0.watermark = mark
        }
        XCTAssertEqual(output.map(\.lastPathComponent), ["photo - Watermarked.jpg"])
        let result = try ImageEngine.load(output[0])
        XCTAssertEqual(result.width, 800)
        XCTAssertLessThan(pixel(result, x: 20, y: 20)[0], 60, "Top left stays untouched")
        let lowerRight = (560..<780).flatMap { x in
            stride(from: 330, to: 390, by: 4).map { pixel(result, x: x, y: $0)[0] }
        }
        XCTAssertGreaterThan(lowerRight.max() ?? 0, 200, "White text appears at the bottom right")
    }

    func testSameSizeFitsAndFills() throws {
        let wide = try image("wide.png", width: 400, height: 100, gray: 0)
        let fitted = try ImageEngine.load(
            try run(.uniformSize, [wide]) {
                var size = UniformSizeOptions()
                size.width = 200
                size.height = 200
                size.background = "#FF0000"
                $0.uniformSize = size
            }[0])
        XCTAssertEqual([fitted.width, fitted.height], [200, 200])
        XCTAssertGreaterThan(pixel(fitted, x: 100, y: 5)[0], 200, "Padding uses the background color")
        XCTAssertLessThan(pixel(fitted, x: 100, y: 100)[0], 30, "The image stays in the middle")
        var fill = UniformSizeOptions()
        fill.width = 200
        fill.height = 200
        fill.mode = .fill
        fill.background = "#FF0000"
        let filled = try ImageBatchTools.uniform(try ImageEngine.load(wide), options: fill)
        XCTAssertLessThan(pixel(filled, x: 100, y: 5)[0], 30, "Fill crops instead of padding")
    }

    func testAnimatedGIFHasEveryFrameAndDelay() throws {
        let inputs = try (0..<3).map { try image("frame\($0).png", gray: CGFloat($0) / 3) }
        let output = try run(.createAnimation, inputs) {
            var animation = AnimationOptions()
            animation.secondsPerImage = 0.5
            $0.animation = animation
        }
        XCTAssertEqual(output.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let gif =
            (CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
            as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.5, accuracy: 0.01)
    }

    func testSlideshowVideoJoinedAudioAndBatchFrames() throws {
        guard (try? Dependencies.executable("ffmpeg")) != nil else { throw XCTSkip("FFmpeg is not installed.") }
        let inputs = try (0..<2).map { try image("slide\($0).png", width: 320, height: 240, gray: CGFloat($0)) }
        let video = try run(.createAnimation, inputs) {
            var animation = AnimationOptions()
            animation.format = "mp4"
            animation.secondsPerImage = 1
            $0.animation = animation
        }
        let info = try MediaEngine.inspect(video[0])
        XCTAssertEqual(info.duration, 2, accuracy: 0.2)
        XCTAssertEqual(info.video?.width, 320)

        let tones = try (0..<2).map { index -> URL in
            let url = folder.appendingPathComponent("tone\(index).\(index==0 ? "wav":"mp3")")
            try ProcessRunner.run(
                Dependencies.executable("ffmpeg"),
                [
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=\(440+index*220):duration=1", "-ac",
                    index == 0 ? "1" : "2", "-ar", index == 0 ? "22050" : "44100", url.path,
                ])
            return url
        }
        let joined = try run(.joinAudio, tones)
        XCTAssertEqual(joined.map(\.lastPathComponent), ["tone0 Joined.m4a"])
        XCTAssertEqual(try MediaEngine.inspect(joined[0]).duration, 2, accuracy: 0.15)

        let clips = try (0..<2).map { index -> URL in
            let url = folder.appendingPathComponent("clip\(index).mp4")
            try ProcessRunner.run(
                Dependencies.executable("ffmpeg"),
                [
                    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=\(index+1)", "-c:v",
                    "libx264", "-pix_fmt", "yuv420p", url.path,
                ])
            return url
        }
        let frames = try run(.videoSnapshots, clips) { $0.snapshotFraction = 1 }
        XCTAssertEqual(frames.map(\.lastPathComponent), ["clip0 Frame 1.png", "clip1 Frame 1.png"])
    }

    func testRemoveLocationKeepsOtherMetadata() throws {
        guard (try? Dependencies.executable("exiftool")) != nil else { throw XCTSkip("ExifTool is not installed.") }
        let source = try image(
            "trip.jpg",
            properties: [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 29.0, kCGImagePropertyGPSLongitudeRef: "E",
                ],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Filevero Test"],
            ])
        let original =
            CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)
            as? [CFString: Any]
        XCTAssertEqual(
            (original?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String,
            "Filevero Test", "fixture")
        let output = try run(.removeLocation, [source])
        XCTAssertEqual(output.map(\.lastPathComponent), ["trip - No Location.jpg"])
        let properties =
            CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(output[0] as CFURL, nil)!, 0, nil)
            as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(
            (properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String,
            "Filevero Test")
        XCTAssertNotNil(
            (CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)
                as? [CFString: Any])?[kCGImagePropertyGPSDictionary], "The original keeps its location")
    }

    func testPDFWatermarkAndPageNumbersKeepTextAndWebLinks() throws {
        let source = try pdf("report.pdf")
        let original = try XCTUnwrap(PDFDocument(url: source))
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/report")
        original.page(at: 0)!.addAnnotation(link)
        let saved = original.dataRepresentation()
        try XCTUnwrap(saved).write(to: source)

        let marked = try run(.watermark, [source]) {
            var mark = WatermarkOptions()
            mark.text = "CONFIDENTIAL"
            mark.position = .center
            $0.watermark = mark
        }
        let numbered = try run(.pageNumbers, [marked[0]]) {
            var numbers = PageNumberOptions()
            numbers.showTotal = true
            $0.pageNumbers = numbers
        }
        let result = try XCTUnwrap(PDFDocument(url: numbered[0]))
        XCTAssertEqual(result.pageCount, 3)
        let text = result.page(at: 1)?.string ?? ""
        XCTAssertTrue(text.contains("Page 2") && text.contains("CONFIDENTIAL") && text.contains("2 / 3"), text)
        let copiedLink = result.page(at: 0)?.annotations.first { $0.type == "Link" }
        XCTAssertEqual(copiedLink?.url?.absoluteString, "https://example.com/report")
    }

    func testPasswordProtectAndUnlockRoundTrip() throws {
        let source = try pdf("secret.pdf")
        XCTAssertThrowsError(try run(.protectPDF, [source]) { $0.password = "12" })
        XCTAssertThrowsError(
            try run(.protectPDF, [source]) { $0.password = "sır-1234" },
            "A non-ASCII password would leave the PDF unprotected")
        let protected = try run(.protectPDF, [source]) { $0.password = "Secret-1234" }
        let locked = try XCTUnwrap(PDFDocument(url: protected[0]))
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.unlock(withPassword: "wrong"))
        XCTAssertThrowsError(try run(.unlockPDF, [protected[0]]) { $0.password = "wrong" })
        XCTAssertThrowsError(
            try run(.pageNumbers, [protected[0]]) { $0.password = "Secret-1234" },
            "Stamping would silently drop the password")
        let unlocked = try run(.unlockPDF, [protected[0]]) { $0.password = "Secret-1234" }
        let opened = try XCTUnwrap(PDFDocument(url: unlocked[0]))
        XCTAssertFalse(opened.isEncrypted)
        XCTAssertEqual(opened.page(at: 0)?.string?.contains("Page 1"), true)
    }

    func testPDFStampsAndUnlockKeepBookmarksAndInternalLinks() throws {
        let source = try pdf("guide.pdf")
        let drawn = try XCTUnwrap(PDFDocument(url: source))
        // PDFKit only saves an outline on a document it assembled itself.
        let guide = PDFDocument()
        for index in 0..<drawn.pageCount { guide.insert(try XCTUnwrap(drawn.page(at: index)), at: index) }
        let bookmarks = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter 3"
        chapter.destination = PDFDestination(page: try XCTUnwrap(guide.page(at: 2)), at: CGPoint(x: 0, y: 400))
        bookmarks.insertChild(chapter, at: 0)
        guide.outlineRoot = bookmarks
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(guide.page(at: 1)), at: .zero))
        guide.page(at: 0)!.addAnnotation(link)
        XCTAssertTrue(guide.write(to: source))

        func assertNavigation(_ output: URL, line: UInt = #line) throws {
            let result = try XCTUnwrap(PDFDocument(url: output))
            let bookmark = try XCTUnwrap(result.outlineRoot?.child(at: 0), line: line)
            XCTAssertEqual(bookmark.label, "Chapter 3", line: line)
            XCTAssertEqual(bookmark.destination?.page.map(result.index(for:)), 2, line: line)
            let jump = result.page(at: 0)?.annotations.compactMap { $0.action as? PDFActionGoTo }.first
            XCTAssertEqual(jump?.destination.page.map(result.index(for:)), 1, line: line)
        }
        try assertNavigation(try run(.watermark, [source])[0])
        try assertNavigation(try run(.pageNumbers, [source])[0])
        let protected = try run(.protectPDF, [source]) { $0.password = "Secret-1234" }
        try assertNavigation(try run(.unlockPDF, protected) { $0.password = "Secret-1234" }[0])
    }

    func testCombineIntoPDFKeepsSelectionOrder() throws {
        let first = try pdf("a.pdf", pages: 2, text: "First")
        let picture = try image("b.png")
        let text = folder.appendingPathComponent("c.txt")
        try Data("Plain text page".utf8).write(to: text)
        let output = try run(.combineToPDF, [first, picture, text])
        XCTAssertEqual(output.map(\.lastPathComponent), ["a - Combined.pdf"])
        let combined = try XCTUnwrap(PDFDocument(url: output[0]))
        XCTAssertEqual(combined.pageCount, 4)
        XCTAssertEqual(combined.page(at: 1)?.string?.contains("First 2"), true)
        XCTAssertEqual(combined.page(at: 3)?.string?.contains("Plain text page"), true)
    }
}
