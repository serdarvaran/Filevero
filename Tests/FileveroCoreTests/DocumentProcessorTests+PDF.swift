import CoreText
import Foundation
import PDFKit
import XCTest

@testable import FileveroCore

extension DocumentEngineTests {
    func testPDFPreservePagesModeEmbedsOneFullPageImagePerPage() throws {
        let pdf = try richFixture()
        let original = try Data(contentsOf: pdf)
        var options = OperationOptions()
        options.pdfOfficeLayout = "preservePages"
        options.dpi = 72
        for format in ["docx", "pages"] {
            let result = try XCTUnwrap(DocumentEngine.convert(pdf, to: format, options: options, token: .init()).first)
            if format == "docx" {
                let package = root.appendingPathComponent("Preserved DOCX", isDirectory: true)
                try ArchiveCodec.extract(result, into: package, token: .init())
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        at: package.appendingPathComponent("word/media"), includingPropertiesForKeys: nil
                    ).count, 2)
                let xml = try XMLDocument(
                    contentsOf: package.appendingPathComponent("word/document.xml"),
                    options: [.nodeLoadExternalEntitiesNever])
                XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='blip']").count, 2)
            } else {
                let model = try PagesCodec.model(result, token: .init())
                let runs = (model["blocks"] as? [[String: Any]] ?? []).flatMap { $0["runs"] as? [[String: Any]] ?? [] }
                XCTAssertEqual(runs.filter { $0["type"] as? String == "image" }.count, 2)
            }
            let restored = try convert(result, "pdf")
            let document = try XCTUnwrap(PDFDocument(url: restored))
            XCTAssertEqual(document.pageCount, 2, format)
            XCTAssertGreaterThan(
                try withExtendedLifetime(document) { try darkPixels(document.page(at: 0)!) }, 100, format)
        }
        XCTAssertEqual(try Data(contentsOf: pdf), original)
    }

    func testRichPDFCreatesEditableParagraphsTablesAndEmbeddedPicturesInDOCX() throws {
        let source = try richFixture()
        let docx = try convert(source, "docx")
        let package = root.appendingPathComponent("Rich DOCX package", isDirectory: true)
        try ArchiveCodec.extract(docx, into: package, token: .init())
        let xml = try XMLDocument(
            contentsOf: package.appendingPathComponent("word/document.xml"),
            options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
        // NSXMLDocument drops whitespace-only w:t nodes even with the preserve
        // option on this macOS version. SAX keeps the exact OpenXML text Word
        // displays, including standalone xml:space="preserve" separator runs.
        let paragraphReader = WordParagraphReader()
        let parser = XMLParser(data: try Data(contentsOf: package.appendingPathComponent("word/document.xml")))
        parser.delegate = paragraphReader
        XCTAssertTrue(parser.parse())
        let paragraphs = paragraphReader.paragraphs
        XCTAssertTrue(
            paragraphs.contains(where: {
                $0.contains(
                    "This editable paragraph starts on its first line and continues naturally on the second line.")
            }))
        XCTAssertTrue(paragraphs.contains(where: { $0.contains("Second page remains editable.") }))
        let tables = try xml.nodes(forXPath: "//*[local-name()='tbl']")
        XCTAssertEqual(tables.count, 1)
        let table = try XCTUnwrap(tables.first)
        XCTAssertEqual(try table.nodes(forXPath: "./*[local-name()='tr']").count, 3)
        XCTAssertEqual(try table.nodes(forXPath: ".//*[local-name()='tc']").count, 6)
        for text in ["Product", "Units", "Apple", "12", "Orange", "7"] {
            XCTAssertTrue((table.stringValue ?? "").contains(text))
        }
        XCTAssertFalse(try xml.nodes(forXPath: "//*[local-name()='b']").isEmpty)
        let images = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("word/media"), includingPropertiesForKeys: nil)
        XCTAssertEqual(images.count, 1)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: images[0])))
        XCTAssertGreaterThan(bitmap.pixelsWide, 150)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 90)
        let orange = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(orange.redComponent, 0.85)
        XCTAssertLessThan(orange.blueComponent, 0.15)
        let relationships = try XMLDocument(
            contentsOf: package.appendingPathComponent("word/_rels/document.xml.rels"),
            options: [.nodeLoadExternalEntitiesNever])
        XCTAssertTrue(
            try relationships.nodes(forXPath: "//*[contains(@Type,'/image') and @TargetMode='External']").isEmpty)
        let restored = try convert(docx, "pdf")
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: restored)).pageCount, 2)
        XCTAssertTrue(try DocumentText.read(convert(docx, "txt")).contains("Quarterly Tangerine Report"))
    }

    func testFixedEPUBKeepsEveryPDFPageViewportAndRenderedImage() throws {
        let source = try richFixture()
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        pdf.page(at: 1)!.rotation = 90
        let rotated = root.appendingPathComponent("Rotated rich.pdf")
        XCTAssertTrue(pdf.write(to: rotated))
        let original = try Data(contentsOf: rotated)
        var options = OperationOptions()
        options.epubLayout = "fixed"
        options.dpi = 72
        let epub = try XCTUnwrap(DocumentEngine.convert(rotated, to: "epub", options: options, token: .init()).first)
        let bytes = try Data(contentsOf: epub)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(bytes[8], 0)
        XCTAssertEqual(bytes[9], 0)  // The first mimetype entry must be uncompressed.
        let package = root.appendingPathComponent("Fixed EPUB package", isDirectory: true)
        try ArchiveCodec.extract(epub, into: package, token: .init())
        let opf = try XMLDocument(
            contentsOf: package.appendingPathComponent("OEBPS/content.opf"), options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(
            try opf.nodes(forXPath: "//*[local-name()='meta' and @property='rendition:layout']").first?.stringValue,
            "pre-paginated")
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']").count, 2)
        for (number, expected) in [(1, CGSize(width: 612, height: 792)), (2, CGSize(width: 792, height: 612))] {
            let name = String(format: "page-%04d", number)
            let page = try XMLDocument(
                contentsOf: package.appendingPathComponent("OEBPS/pages/\(name).xhtml"),
                options: [.nodeLoadExternalEntitiesNever])
            XCTAssertEqual(
                try page.nodes(forXPath: "//*[local-name()='meta' and @name='viewport']/@content").first?.stringValue,
                "width=\(Int(expected.width)),height=\(Int(expected.height))")
            let png = try XCTUnwrap(
                NSBitmapImageRep(data: Data(contentsOf: package.appendingPathComponent("OEBPS/pages/\(name).png"))))
            XCTAssertEqual(png.pixelsWide, Int(expected.width))
            XCTAssertEqual(png.pixelsHigh, Int(expected.height))
            if number == 1 {
                let photo = try XCTUnwrap(png.colorAt(x: 150, y: 392)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(photo.redComponent, 0.85)
                XCTAssertLessThan(photo.blueComponent, 0.15)
            }
        }
        XCTAssertEqual(try Data(contentsOf: rotated), original)
    }

    func testFixedEPUBIsAlsoAvailableForTextDocuments() throws {
        let source = try file("Fixed document.txt", "Fixed document fixture\n")
        var options = OperationOptions()
        options.epubLayout = "fixed"
        options.dpi = 72
        let epub = try XCTUnwrap(DocumentEngine.convert(source, to: "epub", options: options, token: .init()).first)
        let package = root.appendingPathComponent("Text EPUB package", isDirectory: true)
        try ArchiveCodec.extract(epub, into: package, token: .init())
        let opf = try XMLDocument(
            contentsOf: package.appendingPathComponent("OEBPS/content.opf"), options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']").count, 1)
        XCTAssertEqual(
            try opf.nodes(forXPath: "//*[local-name()='meta' and @property='rendition:layout']").first?.stringValue,
            "pre-paginated")
    }

    func testPDFImageScannerRespectsNestedTransformsAndFormImages() throws {
        let output = root.appendingPathComponent("Nested image.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, nil))
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        image.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: 100, y: 200)
        context.scaleBy(x: 2, y: 3)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.draw(image.makeImage()!, in: CGRect(x: 0, y: 0, width: 40, height: 30))
        context.endTransparencyLayer()
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        let regions = try PDFPlacedImages.regions(page, token: .init())
        XCTAssertEqual(regions.count, 1)
        let rect = try XCTUnwrap(regions.first)
        XCTAssertEqual(rect.minX, 100, accuracy: 0.1)
        XCTAssertEqual(rect.minY, 200, accuracy: 0.1)
        XCTAssertEqual(rect.width, 80, accuracy: 0.1)
        XCTAssertEqual(rect.height, 90, accuracy: 0.1)
    }
}

extension DocumentEngineTests {
    private final class WordParagraphReader: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current: String?
        private var inText = false
        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes: [String: String]
        ) {
            if name == "w:p" { current = "" }
            if name == "w:t" { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current? += string } }
        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if name == "w:t" { inText = false }
            if name == "w:p", let value = current {
                paragraphs.append(value)
                current = nil
            }
        }
    }
}
