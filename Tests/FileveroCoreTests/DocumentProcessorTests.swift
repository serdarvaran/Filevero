import AppKit
import CoreText
import Foundation
import PDFKit
import XCTest

@testable import FileveroCore

final class DocumentEngineTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testCancellationProducesNoPublishedDocumentOrExtractedFolder() throws {
        let input = try file("Cancelled.txt", "content")
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try DocumentEngine.convert(input, to: "docx", options: .init(), token: token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cancelled.docx").path))
    }

    func testOfficeTextMarkdownAndEPUBRoutesPreserveContent() throws {
        let markdown = try file(
            "Document.md",
            "# Filevero fixture\n\nMerhaba Şişli & café.\n\n- Apple\n- Orange\n\n**Bold text** and *italic text*.\n")
        let original = try Data(contentsOf: markdown)
        let docx = try convert(markdown, "docx")
        let txt = try convert(docx, "txt")
        XCTAssertTrue(try DocumentText.read(txt).contains("Merhaba Şişli"))
        let html = try convert(docx, "html")
        XCTAssertTrue(try DocumentText.read(html).contains("Filevero fixture"))
        let md = try convert(docx, "md")
        XCTAssertTrue(try DocumentText.read(md).contains("Filevero fixture"))
        let epub = try convert(docx, "epub")
        let restored = try convert(epub, "docx")
        let restoredText = try convert(restored, "txt")
        XCTAssertTrue(try DocumentText.read(restoredText).contains("Merhaba Şişli"))
        let pdf = try convert(markdown, "pdf")
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: pdf)).pageCount, 0)
        var options = OperationOptions()
        options.dpi = 72
        let png = try DocumentEngine.convert(docx, to: "png", options: options, token: .init())
        XCTAssertFalse(png.isEmpty)
        for image in png {
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
            XCTAssertTrue(image.path.hasPrefix(root.path + "/"))
            XCTAssertNotNil(NSImage(contentsOf: image))
        }
        XCTAssertEqual(try Data(contentsOf: markdown), original)
    }

    func testRTFRTFDAndLegacyResourceForkClippingToDOCX() throws {
        let attributed = NSAttributedString(
            string: "Legacy fixture Şişli\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtf = root.appendingPathComponent("Rich.rtf")
        try rtfData.write(to: rtf)
        let rtfd = root.appendingPathComponent("Rich.rtfd", isDirectory: true)
        let wrapper = try attributed.fileWrapper(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: rtfd, options: .atomic, originalContentsURL: nil)
        let clipping = root.appendingPathComponent("Legacy.textClipping")
        try Data().write(to: clipping)
        try Self.resourceFork(type: "utf8", payload: Data("Legacy fixture Şişli\n".utf8)).write(
            to: URL(fileURLWithPath: clipping.path + "/..namedfork/rsrc"))
        for source in [rtf, rtfd, clipping] {
            let output = try convert(source, "docx")
            let txt = try convert(output, "txt")
            XCTAssertTrue(try DocumentText.read(txt).contains("Legacy fixture Şişli"), source.lastPathComponent)
        }
    }

    func testUTF16TextInputIsNormalizedBeforeOfficeImport() throws {
        let input = root.appendingPathComponent("UTF16.txt")
        try "UTF16 fixture Şişli\n".data(using: .utf16)!.write(to: input)
        XCTAssertTrue(try DocumentText.read(convert(convert(input, "docx"), "txt")).contains("UTF16 fixture Şişli"))
    }

    func testRTFDAttachmentSurvivesDOCXAndSelfContainedHTML() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<24 {
            for x in 0..<32 { bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0, alpha: 1), atX: x, y: y) }
        }
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let wrapper = FileWrapper(regularFileWithContents: image)
        wrapper.preferredFilename = "orange.png"
        let text = NSMutableAttributedString(string: "Image fixture\n")
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let rtfd = root.appendingPathComponent("With image.rtfd", isDirectory: true)
        try text.fileWrapper(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ).write(to: rtfd, options: .atomic, originalContentsURL: nil)
        let docx = try convert(rtfd, "docx")
        let package = root.appendingPathComponent("DOCX package", isDirectory: true)
        try ArchiveCodec.extract(docx, into: package, token: .init())
        let media = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("word/media"), includingPropertiesForKeys: nil)
        XCTAssertFalse(media.isEmpty)
        let html = try DocumentText.read(convert(docx, "html"))
        XCTAssertTrue(html.contains("data:image/"))
        XCTAssertFalse(html.contains("src=\"file:"))
    }

    func testSpreadsheetFormulaSurvivesXLSXODSRoundTrip() throws {
        let source = try file(
            "Formula.fods",
            """
            <?xml version="1.0"?><office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.spreadsheet"><office:body><office:spreadsheet><table:table table:name="Formula"><table:table-row><table:table-cell office:value-type="float" office:value="3"><text:p>3</text:p></table:table-cell><table:table-cell office:value-type="float" office:value="4"><text:p>4</text:p></table:table-cell><table:table-cell table:formula="of:=SUM([.A1:.B1])" office:value-type="float" office:value="7"><text:p>7</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document>
            """)
        let xlsx = try DocumentEngine.office(
            source, to: "xlsx", in: root.appendingPathComponent("Initial workbook", isDirectory: true), token: .init())
        let restored = try convert(convert(xlsx, "ods"), "xlsx")
        let package = root.appendingPathComponent("XLSX package", isDirectory: true)
        try ArchiveCodec.extract(restored, into: package, token: .init())
        let xml = try DocumentText.read(package.appendingPathComponent("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(xml.contains("SUM(A1:B1)"))
        XCTAssertTrue(try DocumentText.read(convert(restored, "csv")).contains("3,4,7"))
    }

    func testScannedPDFUsesLocalOCRForTextConversion() throws {
        let width = 1000
        let height = 220
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let value = NSAttributedString(
            string: "Offline OCR fixture 12345",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 30, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
        let image = try XCTUnwrap(context.makeImage())
        let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: width, height: height))))
        let pdf = PDFDocument()
        pdf.insert(page, at: 0)
        let source = root.appendingPathComponent("Scanned.pdf")
        XCTAssertTrue(pdf.write(to: source))
        XCTAssertTrue(try DocumentText.read(convert(source, "txt")).contains("Offline OCR fixture 12345"))
    }

    func testEncryptedPDFRequiresAndAcceptsTheSuppliedPassword() throws {
        let document = try XCTUnwrap(PDFDocument(url: makePDF()))
        let source = root.appendingPathComponent("Encrypted.pdf")
        XCTAssertTrue(
            document.write(
                to: source, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "fixture password"]))
        XCTAssertThrowsError(try DocumentEngine.convert(source, to: "txt", options: .init(), token: .init()))
        var options = OperationOptions()
        options.password = "fixture password"
        let text = try XCTUnwrap(DocumentEngine.convert(source, to: "txt", options: options, token: .init()).first)
        XCTAssertTrue(try DocumentText.read(text).contains("Filevero fixture"))
    }

    func testSpreadsheetConversionsPreserveQuotedCellsUnicodeAndNumbers() throws {
        let csv = try file(
            "Sheet.csv",
            "Name,Amount,Notes\r\n\"Şişli, İstanbul\",12.5,\"Line one\nLine two\"\r\nOrange,7,\"A \"\"quote\"\"\"\r\n")
        let xlsx = try convert(csv, "xlsx")
        let ods = try convert(xlsx, "ods")
        let tsv = try convert(ods, "tsv")
        let text = try DocumentText.read(tsv)
        XCTAssertTrue(text.contains("Şişli, İstanbul"))
        XCTAssertTrue(text.contains("12.5"))
        XCTAssertTrue(text.contains("\t"))
        let restoredXLSX = try convert(tsv, "xlsx")
        let restoredCSV = try convert(restoredXLSX, "csv")
        XCTAssertTrue(try DocumentText.read(restoredCSV).contains("Line one\nLine two"))
        let pdf = try convert(xlsx, "pdf")
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: pdf)).pageCount, 0)
        let xlsFolder = root.appendingPathComponent("XLS", isDirectory: true)
        let xls = try DocumentEngine.office(xlsx, to: "xls", in: xlsFolder, token: .init())
        let fromXLS = try convert(xls, "xlsx")
        XCTAssertTrue(try DocumentText.read(convert(fromXLS, "csv")).contains("Şişli, İstanbul"))
    }

    func testPDFToEditableTextDOCXXLSXEPUBAndPageBasedPPTX() throws {
        let pdf = try makePDF()
        let txt = try convert(pdf, "txt")
        XCTAssertTrue(try DocumentText.read(txt).contains("Filevero fixture"))
        XCTAssertTrue(try DocumentText.read(convert(pdf, "md")).contains("Page two"))
        let docx = try convert(pdf, "docx")
        XCTAssertTrue(try DocumentText.read(convert(docx, "txt")).contains("Filevero fixture"))
        let epub = try convert(pdf, "epub")
        XCTAssertTrue(try DocumentText.read(convert(epub, "txt")).contains("Page two"))
        let xlsx = try convert(pdf, "xlsx")
        let csv = try convert(xlsx, "csv")
        XCTAssertTrue(try DocumentText.read(csv).contains("Apple"))
        let pptx = try convert(pdf, "pptx")
        let archive = root.appendingPathComponent("PPTX package", isDirectory: true)
        try ArchiveCodec.extract(pptx, into: archive, token: .init())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archive.appendingPathComponent("ppt/slides/slide1.xml").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archive.appendingPathComponent("ppt/slides/slide2.xml").path))
        let slidesPDF = try convert(pptx, "pdf")
        let renderedSlides = try XCTUnwrap(PDFDocument(url: slidesPDF))
        XCTAssertEqual(renderedSlides.pageCount, 2)
        XCTAssertGreaterThan(
            try withExtendedLifetime(renderedSlides) { try darkPixels(renderedSlides.page(at: 0)!) }, 100)
        var options = OperationOptions()
        options.dpi = 72
        for format in ["jpg", "png"] {
            let images = try DocumentEngine.convert(pptx, to: format, options: options, token: .init())
            XCTAssertEqual(images.count, 2)
            for image in images { XCTAssertNotNil(NSImage(contentsOf: image)) }
        }
        let pptFolder = root.appendingPathComponent("PPT", isDirectory: true)
        let ppt = try DocumentEngine.office(pptx, to: "ppt", in: pptFolder, token: .init())
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: convert(ppt, "pdf"))).pageCount, 2)
    }

    func testNativePagesRoundTripUsesCopiedInputs() throws {
        let txt = try file("Native.txt", "Native Pages fixture Şişli\n")
        let docx = try convert(txt, "docx")
        let original = try Data(contentsOf: docx)
        let pages = try convert(docx, "pages")
        XCTAssertTrue(try DocumentText.read(convert(pages, "txt")).contains("Native Pages fixture Şişli"))
        let restored = try convert(pages, "docx")
        XCTAssertTrue(try DocumentText.read(convert(restored, "txt")).contains("Native Pages fixture Şişli"))
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: convert(pages, "pdf"))).pageCount, 0)
        XCTAssertEqual(try Data(contentsOf: docx), original)
    }

    func testOfflinePagesPreservesEditableParagraphsTablesAndEmbeddedImages() throws {
        let pdf = try richFixture()
        let docx = try convert(pdf, "docx")
        let original = try Data(contentsOf: pdf)
        let pages = try convert(docx, "pages")
        let model = try PagesCodec.model(pages, token: .init())
        let blocks = try XCTUnwrap(model["blocks"] as? [[String: Any]])
        let paragraphs = blocks.filter { $0["type"] as? String == "paragraph" }
        // The binary fixture document was authored with this title.
        let runs = paragraphs.flatMap { $0["runs"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(runs.compactMap { $0["text"] as? String }.joined().contains("Quarterly Tangerine Report"))
        XCTAssertTrue(runs.contains { ($0["character"] as? [String: Any])?["bold"] as? Bool == true })
        let table = try XCTUnwrap(blocks.first { $0["type"] as? String == "table" })
        let rows = try XCTUnwrap(table["rows"] as? [[[String: Any]]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[1][0]["text"] as? String, "Apple")
        XCTAssertEqual(rows[1][1]["text"] as? String, "12")
        let image = try XCTUnwrap(runs.first { $0["type"] as? String == "image" })
        let imageData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image["data"] as? String)))
        XCTAssertNotNil(NSImage(data: imageData))
        let restored = try convert(pages, "docx")
        let package = root.appendingPathComponent("Restored Pages DOCX", isDirectory: true)
        try ArchiveCodec.extract(restored, into: package, token: .init())
        let xml = try XMLDocument(
            contentsOf: package.appendingPathComponent("word/document.xml"), options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='tbl']").count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: package.appendingPathComponent("word/media"), includingPropertiesForKeys: nil
            ).count, 1)
        XCTAssertTrue(try DocumentText.read(convert(restored, "txt")).contains("Second page remains editable."))
        XCTAssertEqual(try Data(contentsOf: pdf), original)
    }

    func testAllSixteenAdvertisedPagesRoutesRunOfflineWithoutApplePages() throws {
        let text = "Offline Pages route fixture Şişli\n"
        let txt = try file("Pages routes.txt", text)
        let docx = try convert(txt, "docx")
        let md = try file("Pages routes.md", text)
        let rtf = try DocumentEngine.office(docx, to: "rtf", in: root.appendingPathComponent("RTF"), token: .init())
        let attributed = NSAttributedString(string: text)
        let rtfd = root.appendingPathComponent("Pages routes.rtfd", isDirectory: true)
        try attributed.fileWrapper(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ).write(to: rtfd, options: .atomic, originalContentsURL: nil)
        let clipping = root.appendingPathComponent("Pages routes.textClipping")
        try PropertyListSerialization.data(
            fromPropertyList: ["public.utf8-plain-text": text], format: .binary, options: 0
        ).write(to: clipping)
        let epub = try convert(docx, "epub")
        let pdf = try convert(docx, "pdf")
        var generated: [URL] = []
        for source in [pdf, docx, md, rtf, rtfd, clipping, epub, txt] {
            let pages = try convert(source, "pages")
            generated.append(pages)
            XCTAssertTrue(
                try DocumentText.read(convert(pages, "txt")).contains("Offline Pages route fixture"),
                source.pathExtension)
        }
        let pages = try XCTUnwrap(generated.first)
        var options = OperationOptions()
        options.dpi = 72
        for format in FeatureCatalog.conversionMatrix["pages"] ?? [] {
            let outputs = try DocumentEngine.convert(pages, to: format, options: options, token: .init())
            XCTAssertFalse(outputs.isEmpty, format)
            try OutputFiles.validate(outputs)
            if ["jpg", "png"].contains(format) { XCTAssertNotNil(NSImage(contentsOf: outputs[0])) }
            if format == "pdf" { XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: outputs[0])).pageCount, 0) }
        }
    }

    func testPagesRejectsMalformedInputAndCancellationPreservesSource() throws {
        let bad = try file("Invalid.pages", "PK this is not an iWork archive")
        let original = try Data(contentsOf: bad)
        XCTAssertThrowsError(try DocumentEngine.convert(bad, to: "docx", options: .init(), token: .init()))
        XCTAssertEqual(try Data(contentsOf: bad), original)
        let source = try file("Cancel Pages.txt", "Cancellation fixture\n")
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try DocumentEngine.convert(source, to: "pages", options: .init(), token: token))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("pages").path))
        XCTAssertEqual(try DocumentText.read(source), "Cancellation fixture\n")
    }

    func convert(_ input: URL, _ format: String) throws -> URL {
        try XCTUnwrap(DocumentEngine.convert(input, to: format, options: .init(), token: .init()).first)
    }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func richFixture() throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Reference/document-fixtures/rich.pdf")
        let copy = root.appendingPathComponent("Rich document.pdf")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }
    func makePDF() throws -> URL {
        let output = root.appendingPathComponent("Two pages.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &bounds, nil) else {
            throw FileveroError.failed("PDF fixture context failed.")
        }
        for page in 0..<2 {
            context.beginPDFPage(nil)
            func draw(_ value: String, x: CGFloat, y: CGFloat) {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let text = NSAttributedString(
                    string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            draw(page == 0 ? "Filevero fixture" : "Page two", x: 50, y: 730)
            draw("Name", x: 50, y: 650)
            draw("Amount", x: 250, y: 650)
            draw("Apple", x: 50, y: 620)
            draw("12.5", x: 250, y: 620)
            context.endPDFPage()
        }
        context.closePDF()
        return output
    }
    func darkPixels(_ page: PDFPage) throws -> Int {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 306, height: 396, bitsPerComponent: 8, bytesPerRow: 306 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 306, height: 396))
        context.scaleBy(x: 0.5, y: 0.5)
        page.draw(with: .mediaBox, to: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(306 * 396)).filter { Int(bytes[$0 * 4]) + Int(bytes[$0 * 4 + 1]) + Int(bytes[$0 * 4 + 2]) < 600 }
            .count
    }

    static func little(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func big(_ value: Int, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
    static func resourceFork(type: String, payload: Data) -> Data {
        let dataOffset = 256
        let mapOffset = dataOffset + 4 + payload.count
        let mapLength = 50
        let header =
            big(dataOffset, count: 4) + big(mapOffset, count: 4) + big(4 + payload.count, count: 4)
            + big(mapLength, count: 4)
        var data =
            header + Data(repeating: 0, count: dataOffset - header.count) + big(payload.count, count: 4) + payload
        var map = header + Data(repeating: 0, count: 8) + big(28, count: 2) + big(50, count: 2)
        map += big(0, count: 2) + Data(type.utf8) + big(0, count: 2) + big(10, count: 2)
        map += big(128, count: 2) + big(0xffff, count: 2) + Data(repeating: 0, count: 8)
        data += map
        return data
    }
}
