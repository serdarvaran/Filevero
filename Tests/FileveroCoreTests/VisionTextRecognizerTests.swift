import CoreText
import PDFKit
import XCTest

@testable import FileveroCore

final class TextRecognitionEngineTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try OutputFiles.temporaryDirectory()
        guard try TextRecognitionEngine.availableLanguages().contains("tr-TR") else {
            throw XCTSkip("This macOS version has no Turkish OCR.")
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let lines = ["Çalışma Raporu Şubat", "Güneşli öğleden sonra", "Istanbul Kadıköy"]

    /// A scan: text exists only as pixels.
    private func scannedImage(_ lines: [String]) throws -> CGImage {
        let width = 1700
        let height = 2200
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                    ]))
            context.textPosition = CGPoint(x: 150, y: height - 300 - index * 160)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func pdf(_ name: String, pages: [(scan: CGImage?, text: String?)]) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            if let scan = page.scan { context.draw(scan, in: box) }
            if let text = page.text {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                                "Helvetica" as CFString, 18, nil)
                        ]))
                context.textPosition = CGPoint(x: 72, y: 40)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func options(_ output: String, languages: [String] = TextRecognitionEngine.defaultLanguages)
        -> OperationOptions
    {
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent("Out", isDirectory: true)
        options.ocrOutput = output
        options.ocrLanguages = languages
        options.revealInFinder = false
        return options
    }
    private func run(_ input: URL, _ options: OperationOptions) throws -> [URL] {
        try ConversionEngine.run(.init(inputs: [input], operation: .tool(.recognizeText), options: options))
    }
    private func assertRecognized(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let folded = text.lowercased()
        for word in ["çalışma", "raporu", "güneşli", "öğleden", "kadıköy"] {
            XCTAssertTrue(folded.contains(word), "\(word) missing in: \(text)", file: file, line: line)
        }
    }

    func testScannedPDFGainsATextLayerAndKeepsPagesAndSource() throws {
        let input = try pdf("Tarama.pdf", pages: [(try scannedImage(lines), nil)])
        let before = try Data(contentsOf: input)
        let output = try XCTUnwrap(run(input, options("pdf")).first)
        XCTAssertEqual(output.lastPathComponent, "Tarama - Searchable.pdf")
        let searchable = try XCTUnwrap(PDFDocument(url: output))
        let original = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertEqual(searchable.pageCount, 1)
        XCTAssertEqual(searchable.page(at: 0)?.bounds(for: .mediaBox), original.page(at: 0)?.bounds(for: .mediaBox))
        assertRecognized(searchable.page(at: 0)?.string ?? "")
        XCTAssertNotNil(searchable.findString("Raporu", withOptions: .caseInsensitive).first)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testPagesWithExistingTextAreKeptWhileScannedPagesAreRecognized() throws {
        let input = try pdf(
            "Karışık.pdf",
            pages: [(nil, "Zaten seçilebilir metin içeren, aranabilir bir sayfa"), (try scannedImage(lines), nil)])
        let searchable = try XCTUnwrap(PDFDocument(url: XCTUnwrap(run(input, options("pdf")).first)))
        XCTAssertEqual(searchable.pageCount, 2)
        XCTAssertEqual(
            searchable.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Zaten seçilebilir metin içeren, aranabilir bir sayfa")
        assertRecognized(searchable.page(at: 1)?.string ?? "")
    }

    func testAPageNumberAloneDoesNotMakeAScanSearchable() throws {
        let input = try pdf("Damgalı.pdf", pages: [(try scannedImage(lines), "Sayfa 1")])
        let searchable = try XCTUnwrap(PDFDocument(url: XCTUnwrap(run(input, options("pdf")).first)))
        assertRecognized(searchable.page(at: 0)?.string ?? "")
    }

    func testPasswordProtectedPDFIsNotCopiedWithoutItsProtection() throws {
        let plain = try XCTUnwrap(PDFDocument(url: pdf("Açık.pdf", pages: [(try scannedImage(lines), nil)])))
        let locked = root.appendingPathComponent("Kilitli.pdf")
        XCTAssertTrue(
            plain.write(to: locked, withOptions: [.userPasswordOption: "parola", .ownerPasswordOption: "sahip"]))
        var settings = options("pdf")
        settings.password = "parola"
        XCTAssertThrowsError(try run(locked, settings)) { error in
            guard case FileveroError.unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Out").path)) ?? [], [])
    }

    func testImageCanBeSavedAsPlainText() throws {
        let image = root.appendingPathComponent("Fotoğraf.png")
        try ImageEngine.write(scannedImage(lines), to: image)
        let output = try XCTUnwrap(run(image, options("txt")).first)
        XCTAssertEqual(output.lastPathComponent, "Fotoğraf.txt")
        assertRecognized(try String(contentsOf: output, encoding: .utf8))
    }

    func testRejectsUnavailableLanguageAlreadySearchablePDFAndSignedPDFWithoutWriting() throws {
        let scanned = try pdf("Tarama.pdf", pages: [(try scannedImage(lines), nil)])
        XCTAssertThrowsError(try run(scanned, options("pdf", languages: ["xx-XX"])))
        XCTAssertThrowsError(try run(scanned, options("pdf", languages: [])))
        XCTAssertThrowsError(try run(scanned, options("docx")))
        let searchable = try pdf("Metin.pdf", pages: [(nil, "Bu sayfada zaten seçilebilir ve aranabilir metin var")])
        XCTAssertThrowsError(try run(searchable, options("pdf")))

        let signed = try XCTUnwrap(PDFDocument(url: scanned))
        let field = PDFAnnotation(
            bounds: CGRect(x: 72, y: 72, width: 200, height: 50), forType: .widget, withProperties: nil)
        field.widgetFieldType = .signature
        field.fieldName = "İmza"
        signed.page(at: 0)?.addAnnotation(field)
        let signedURL = root.appendingPathComponent("İmzalı.pdf")
        XCTAssertTrue(signed.write(to: signedURL))
        XCTAssertEqual(PDFDocument(url: signedURL)?.page(at: 0)?.annotations.first?.widgetFieldType, .signature)
        XCTAssertThrowsError(try run(signedURL, options("pdf")))
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Out").path)) ?? [], [])
    }
}
