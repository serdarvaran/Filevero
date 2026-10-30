import PDFKit
import XCTest

@testable import FileveroCore

final class FileNameSuggesterTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testModelOutputBecomesASafeSingleLineStem() {
        XCTAssertEqual(
            FileNameSuggester.cleaned("\"Fatura 2024/118.pdf\"\nBecause it is an invoice."), "Fatura 2024 118")
        XCTAssertEqual(FileNameSuggester.cleaned("  ..kira:sözleşmesi  "), "kira sözleşmesi")
        XCTAssertEqual(
            FileNameSuggester.cleaned("Versiyon 1.2"), "Versiyon 1.2", "Numbers are not mistaken for an extension")
        XCTAssertNil(FileNameSuggester.cleaned(" \n ./ "))
        XCTAssertEqual(FileNameSuggester.cleaned(String(repeating: "a", count: 200))?.count, 80)
    }

    func testContentComesFromDocumentTextAndPDFTextLayer() throws {
        let text = folder.appendingPathComponent("not.txt")
        try Data("  Fatura No: 2024-118\n\n\nTutar: 1.250 TL ".utf8).write(to: text)
        XCTAssertEqual(try FileNameSuggester.content(of: text), "Fatura No: 2024-118\nTutar: 1.250 TL")

        let pdf = folder.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Kira Sözleşmesi Kadıköy",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString, 16, nil)
                ]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        XCTAssertTrue(try FileNameSuggester.content(of: pdf).contains("Kira Sözleşmesi"))

        XCTAssertFalse(FileNameSuggester.supports(folder.appendingPathComponent("song.mp3")))
        XCTAssertTrue(FileNameSuggester.supports(folder.appendingPathComponent("photo.heic")))
        XCTAssertFalse(FileNameSuggester.supports(folder.appendingPathComponent("page.html")))
    }

    func testSuggestedNamesReplaceNameButKeepExtensionAndTemplate() throws {
        let first = folder.appendingPathComponent("IMG_001.pdf")
        let second = folder.appendingPathComponent("IMG_002.pdf")
        for url in [first, second] { try Data("x".utf8).write(to: url) }
        var options = RenameOptions()
        options.template = "{n} {name}"
        let rows = BatchRename.preview([first, second], options: options, suggestions: [first: "Kira Sözleşmesi"])
        XCTAssertEqual(rows.map(\.name), ["1 Kira Sözleşmesi.pdf", "2 IMG_002.pdf"])
    }

    /// Calls the real on-device model, so it runs only when asked for and available.
    func testLiveSuggestionForAnInvoice() async throws {
        guard ProcessInfo.processInfo.environment["FILEVERO_TEST_APPLE_INTELLIGENCE"] == "1" else {
            throw XCTSkip("Set FILEVERO_TEST_APPLE_INTELLIGENCE=1 to use the on-device model.")
        }
        guard FileNameSuggester.status == .available else {
            throw XCTSkip("Apple Intelligence is not available on this Mac.")
        }
        let invoice = folder.appendingPathComponent("Scan 0001.txt")
        try Data("FATURA\nFatura No: 2024-118\nTarih: 12.03.2024\nAlıcı: Deniz Yayıncılık\nToplam: 1.250 TL".utf8)
            .write(to: invoice)
        let name = try await FileNameSuggester.suggest(for: invoice)
        print("SUGGESTED:", name)
        XCTAssertEqual(FileNameSuggester.cleaned(name), name)
        XCTAssertTrue(
            name.localizedCaseInsensitiveContains("fatura") || name.localizedCaseInsensitiveContains("invoice")
                || name.contains("118"), name)

        let photo = folder.appendingPathComponent("IMG_4821.png")
        let context = CGContext(
            data: nil, width: 900, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 500))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Uçak Bileti İstanbul → Ankara",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica-Bold" as CFString, 48, nil)
                ]))
        context.textPosition = CGPoint(x: 40, y: 230)
        CTLineDraw(line, context)
        try ImageEngine.write(context.makeImage()!, to: photo)
        let photoName = try await FileNameSuggester.suggest(for: photo)
        print("SUGGESTED IMAGE:", photoName)
        XCTAssertTrue(
            photoName.localizedCaseInsensitiveContains("bilet") || photoName.localizedCaseInsensitiveContains("ankara")
                || photoName.localizedCaseInsensitiveContains("istanbul"), photoName)
    }
}
