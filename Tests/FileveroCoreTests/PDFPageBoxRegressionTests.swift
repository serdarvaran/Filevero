import AppKit
import PDFKit
import XCTest

@testable import FileveroCore

final class PDFPageBoxRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCompressingARotatedScanKeepsItsDisplayedShapeAndContent() throws {
        // PDFKit-written files carry catalog metadata and take the preserving path, so the scan is built by hand.
        let input = root.appendingPathComponent("Rotated scan.pdf")
        try rotatedScan().write(to: input)
        var options = OperationOptions()
        options.outputDirectory = root
        let output = try XCTUnwrap(PDFEngine.tool(.compress, inputs: [input], options: options, token: .init()).first)
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))

        let shown = OfficeDocumentBridge.visualBounds(page)
        XCTAssertEqual(shown.width, 100, accuracy: 1)
        XCTAssertEqual(shown.height, 200, accuracy: 1)
        // Rotating the red-left/blue-right page clockwise puts red on top.
        let image = try rendered(page)
        XCTAssertEqual(try color(image, x: 0.5, y: 0.25), .red)
        XCTAssertEqual(try color(image, x: 0.5, y: 0.75), .blue)
    }

    func testRenderingACroppedPageShowsOnlyTheCropBox() throws {
        let input = try fixture("Cropped") { $0.setBounds(CGRect(x: 100, y: 0, width: 100, height: 100), for: .cropBox) }
        var options = OperationOptions()
        options.outputDirectory = root
        options.dpi = 72
        let output = try XCTUnwrap(PDFEngine.render(input, to: "png", options: options, token: .init()).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
        XCTAssertEqual(image.pixelsWide, 100)
        XCTAssertEqual(image.pixelsHigh, 100)
        XCTAssertEqual(try color(image, x: 0.1, y: 0.5), .blue)
        XCTAssertEqual(try color(image, x: 0.9, y: 0.5), .blue)

        let page = try XCTUnwrap(PDFDocument(url: input)?.page(at: 0))
        let png = try XCTUnwrap(NSBitmapImageRep(data: OfficeDocumentBridge.rasterPNG(page, dpi: 72, token: .init())))
        XCTAssertEqual(png.pixelsWide, 100)
        XCTAssertEqual(try color(png, x: 0.1, y: 0.5), .blue)
    }

    private enum Swatch { case red, blue, other }

    private func fixture(_ name: String, adjust: (PDFPage) -> Void) throws -> URL {
        let source = root.appendingPathComponent(name + " source.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: source as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        context.beginPDFPage(
            [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        adjust(try XCTUnwrap(pdf.page(at: 0)))
        let output = root.appendingPathComponent(name + ".pdf")
        XCTAssertTrue(pdf.write(to: output))
        return output
    }

    private func rotatedScan() -> Data {
        // Thousands of hairline strips make the vector original larger than its JPEG rendering,
        // so compression keeps the rasterized copy instead of falling back to the source.
        func strips(from start: Int) -> String {
            (0..<10_000).map { "\(start * 100 + $0) 0 1 100 re f" }.joined(separator: " ")
        }
        let content = "q 0.01 0 0 1 0 0 cm 1 0 0 rg \(strips(from: 0)) 0 0 1 rg \(strips(from: 100)) Q"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate 90 /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        pdf += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func rendered(_ page: PDFPage) throws -> NSBitmapImageRep {
        let bounds = OfficeDocumentBridge.visualBounds(page)
        let image = page.thumbnail(of: bounds.size, for: .cropBox)
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init))
    }

    private func color(_ image: NSBitmapImageRep, x: Double, y: Double) throws -> Swatch {
        let pixel = try XCTUnwrap(
            image.colorAt(x: Int(Double(image.pixelsWide) * x), y: Int(Double(image.pixelsHigh) * y))?
                .usingColorSpace(.sRGB))
        if pixel.redComponent > 0.8, pixel.blueComponent < 0.5 { return .red }
        if pixel.blueComponent > 0.8, pixel.redComponent < 0.5 { return .blue }
        return .other
    }
}
