import PDFKit
import XCTest

@testable import FileveroCore

final class PDFStampLinkGeometryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let marker = CGRect(x: 200, y: 150, width: 40, height: 30)

    private var markerCenter: CGPoint { CGPoint(x: marker.midX, y: marker.midY) }

    /// Two pages with a black marker and a crop box away from the origin; the second page is rotated. Each page's
    /// marker carries a GoTo link to the other page's marker, and a bookmark points at each marker.
    private func croppedAndRotatedPDF() throws -> URL {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(marker)
            context.endPDFPage()
        }
        context.closePDF()
        let drawn = try XCTUnwrap(PDFDocument(data: data as Data))
        // PDFKit only saves GoTo destinations on a document it assembled itself.
        let pdf = PDFDocument()
        for index in 0..<2 { pdf.insert(try XCTUnwrap(drawn.page(at: index)), at: index) }
        for index in 0..<2 {
            let page = try XCTUnwrap(pdf.page(at: index))
            page.setBounds(CGRect(x: 100, y: 100, width: 250, height: 180), for: .cropBox)
            if index == 1 { page.rotation = 90 }
        }
        let bookmarks = PDFOutline()
        for index in 0..<2 {
            let page = try XCTUnwrap(pdf.page(at: index))
            let other = try XCTUnwrap(pdf.page(at: 1 - index))
            let link = PDFAnnotation(bounds: marker, forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: PDFDestination(page: other, at: markerCenter))
            page.addAnnotation(link)
            let bookmark = PDFOutline()
            bookmark.label = index == 0 ? "Cropped" : "Rotated"
            bookmark.destination = PDFDestination(page: page, at: markerCenter)
            bookmarks.insertChild(bookmark, at: index)
        }
        pdf.outlineRoot = bookmarks
        let url = directory.appendingPathComponent("Cropped.pdf")
        XCTAssertTrue(pdf.write(to: url))
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .cropBox).origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(reopened.page(at: 1)?.rotation, 90)
        XCTAssertEqual(
            (reopened.page(at: 1)?.annotations.first { $0.action is PDFActionGoTo }?.action as? PDFActionGoTo)?
                .destination.point, markerCenter, "fixture needs a GoTo")
        XCTAssertEqual(reopened.outlineRoot?.child(at: 1)?.destination?.point, markerCenter, "fixture needs bookmarks")
        return url
    }

    private func isDark(_ page: PDFPage, at point: CGPoint) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.translateBy(x: -point.x, y: -point.y)
        context.drawPDFPage(try XCTUnwrap(page.pageRef))
        return pixel[0] < 64 && pixel[1] < 64 && pixel[2] < 64
    }

    func testStampedLinksStayOverTheirContentOnCroppedAndRotatedPages() throws {
        let source = try croppedAndRotatedPDF()
        var options = OperationOptions()
        options.outputDirectory = directory
        options.pageNumbers = PageNumberOptions()
        let output = try XCTUnwrap(
            PDFBatchProcessor.run(.pageNumbers, inputs: [source], options: options, token: .init()) { _, _ in }.first)
        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 2)
        for index in 0..<2 {
            let page = try XCTUnwrap(result.page(at: index))
            let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" }, "page \(index + 1) lost its link")
            let bounds = link.bounds
            let expected = index == 0 ? CGSize(width: 40, height: 30) : CGSize(width: 30, height: 40)
            XCTAssertEqual(bounds.width, expected.width, accuracy: 0.5, "page \(index + 1)")
            XCTAssertEqual(bounds.height, expected.height, accuracy: 0.5, "page \(index + 1)")
            XCTAssertTrue(
                try isDark(page, at: CGPoint(x: bounds.midX, y: bounds.midY)),
                "page \(index + 1): link at \(bounds) is not over its marker")
        }
    }

    func testStampedLinkAndBookmarkDestinationsLandOnTheirContentOnCroppedAndRotatedPages() throws {
        let source = try croppedAndRotatedPDF()
        var options = OperationOptions()
        options.outputDirectory = directory
        options.watermark = WatermarkOptions()
        let output = try XCTUnwrap(
            PDFBatchProcessor.run(.watermark, inputs: [source], options: options, token: .init()) { _, _ in }.first)
        let result = try XCTUnwrap(PDFDocument(url: output))
        for index in 0..<2 {
            let target = 1 - index
            let goTo = try XCTUnwrap(
                result.page(at: index)?.annotations.first { $0.type == "Link" }?.action as? PDFActionGoTo,
                "page \(index + 1) lost its GoTo link")
            let linkPage = try XCTUnwrap(goTo.destination.page)
            XCTAssertEqual(result.index(for: linkPage), target)
            XCTAssertTrue(
                try isDark(linkPage, at: goTo.destination.point),
                "GoTo to page \(target + 1) lands at \(goTo.destination.point), away from its marker")

            let bookmark = try XCTUnwrap(result.outlineRoot?.child(at: index)?.destination, "bookmark \(index + 1)")
            let bookmarkPage = try XCTUnwrap(bookmark.page)
            XCTAssertEqual(result.index(for: bookmarkPage), index)
            XCTAssertTrue(
                try isDark(bookmarkPage, at: bookmark.point),
                "bookmark to page \(index + 1) lands at \(bookmark.point), away from its marker")
        }
    }

    func testUnspecifiedDestinationCoordinateStaysUnspecifiedOnItsRotatedAxis() throws {
        let pdf = try XCTUnwrap(PDFDocument(url: try croppedAndRotatedPDF()))
        let unspecified = kPDFDestinationUnspecifiedValue
        for index in 0..<2 {
            let page = try XCTUnwrap(pdf.page(at: index))
            let reference = try XCTUnwrap(page.pageRef)
            let crop = page.bounds(for: .cropBox)
            let size = index == 1 ? CGSize(width: crop.height, height: crop.width) : crop.size
            let transform = reference.getDrawingTransform(
                .cropBox, rect: CGRect(origin: .zero, size: size),
                rotate: Int32(page.rotation) - reference.rotationAngle, preserveAspectRatio: true)
            let full = markerCenter.applying(transform)
            let onlyY = PDFCoreKit.mappedPoint(CGPoint(x: unspecified, y: markerCenter.y), on: page, by: transform)
            let onlyX = PDFCoreKit.mappedPoint(CGPoint(x: markerCenter.x, y: unspecified), on: page, by: transform)
            if index == 0 {
                XCTAssertEqual(onlyY.x, unspecified)
                XCTAssertEqual(onlyY.y, full.y, accuracy: 0.01)
                XCTAssertEqual(onlyX.y, unspecified)
                XCTAssertEqual(onlyX.x, full.x, accuracy: 0.01)
            } else {
                XCTAssertEqual(onlyY.y, unspecified, "a rotated page shows source y across the page")
                XCTAssertEqual(onlyY.x, full.x, accuracy: 0.01)
                XCTAssertEqual(onlyX.x, unspecified)
                XCTAssertEqual(onlyX.y, full.y, accuracy: 0.01)
            }
        }
    }

    func testUniformWidthFailsInsteadOfDroppingAnUnreadablePage() throws {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let unbacked = PDFPage()
        XCTAssertNil(unbacked.pageRef, "fixture needs a page without a Core Graphics page")
        pdf.insert(unbacked, at: 1)
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertThrowsError(try PDFCoreKit.uniformWidth(pdf)) { error in
            guard case FileveroError.failed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "A PDF page could not be read.")
        }
    }
}
