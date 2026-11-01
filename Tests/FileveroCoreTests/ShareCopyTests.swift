import CoreGraphics
import ImageIO
import PDFKit
import XCTest

@testable import FileveroCore

final class ShareCopyTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func photo(_ name: String, width: Int, height: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let metadata =
            [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Ayşe Yılmaz"],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
                ],
            ] as CFDictionary
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url, quality: 0.9, metadata: metadata)
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func share(_ inputs: [URL]) throws -> [URL] {
        var options = OperationOptions()
        options.revealInFinder = false
        return try ConversionEngine.run(
            ConversionRequest(inputs: inputs, operation: .tool(.prepareToShare), options: options), token: .init())
    }

    func testHEICBecomesAJPGShareCopyThatFitsAndCarriesNoPersonalMetadata() throws {
        let input = try photo("Tatil.heic", width: 4000, height: 3000)
        let before = try Data(contentsOf: input)
        let outputs = try share([input])
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Tatil - Share.jpg"])
        let result = try properties(outputs[0])
        XCTAssertEqual(result[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(result[kCGImagePropertyPixelHeight] as? Int, 1536)
        XCTAssertNil(result[kCGImagePropertyGPSDictionary])
        XCTAssertNil((result[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testWebFriendlyImagesKeepTheirFormatAndAreNeverEnlarged() throws {
        let inputs = try [photo("Ekran.png", width: 640, height: 480), photo("Kare.jpg", width: 900, height: 900)]
        let outputs = try share(inputs)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Ekran - Share.png", "Kare - Share.jpg"])
        XCTAssertEqual(try properties(outputs[0])[kCGImagePropertyPixelWidth] as? Int, 640)
        XCTAssertNil(try properties(outputs[1])[kCGImagePropertyGPSDictionary])
    }

    func testPDFShareCopyDropsDocumentAttributes() throws {
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        pdf.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Ayşe Yılmaz"]
        let input = root.appendingPathComponent("Teklif.pdf")
        XCTAssertTrue(pdf.write(to: input))
        let outputs = try share([input])
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Teklif - Share.pdf"])
        let author = PDFDocument(url: outputs[0])?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        XCTAssertNil(author)
    }

    func testPrepareToShareIsOfferedWhereverMetadataCanBeRemoved() {
        let urls = ["a.jpg", "b.heic", "c.pdf", "d.mp4", "e.mp3", "f.dng"].map { root.appendingPathComponent($0) }
        for url in urls {
            XCTAssertTrue(FeatureCatalog.tools(for: [url]).contains(.prepareToShare), url.lastPathComponent)
        }
        XCTAssertTrue(FeatureCatalog.tools(for: Array(urls.prefix(3))).contains(.prepareToShare))
        XCTAssertFalse(FeatureCatalog.tools(for: [root.appendingPathComponent("g.docx")]).contains(.prepareToShare))
    }
}
