import PDFKit
import XCTest

@testable import FileveroCore

/// DOC, ODT and HTML inputs are converted through LibreOffice on macOS.
final class DocumentRouteTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        guard (try? Dependencies.executable("soffice")) != nil else { throw XCTSkip("LibreOffice is not installed.") }
        root = try OutputFiles.temporaryDirectory()
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func html() throws -> URL {
        let url = root.appendingPathComponent("Çalışma Raporu.html")
        try Data(
            """
            <!doctype html><html><head><meta charset="utf-8"><title>Rapor</title></head><body>
            <h1>Çalışma raporu Şubat</h1><p>Güneşli öğleden sonra ölçümler tamamlandı.</p>
            <table><tr><th>Şehir</th><th>Değer</th></tr><tr><td>İstanbul</td><td>42</td></tr></table>
            </body></html>
            """.utf8
        ).write(to: url)
        return url
    }
    private func convert(_ input: URL, _ format: String) throws -> URL {
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent("Out-\(format)", isDirectory: true)
        options.revealInFinder = false
        return try XCTUnwrap(
            ConversionEngine.run(.init(inputs: [input], operation: .convert(format), options: options)).first)
    }
    private func text(of url: URL) throws -> String {
        url.pathExtension == "pdf"
            ? (PDFDocument(url: url)?.string ?? "")
            : try DocumentText.read(url.pathExtension == "txt" || url.pathExtension == "md" ? url : convert(url, "txt"))
    }
    private func assertContent(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try text(of: url)
        for word in ["Çalışma raporu Şubat", "Güneşli öğleden", "İstanbul", "42"] {
            XCTAssertTrue(
                value.contains(word), "\(word) missing from \(url.lastPathComponent): \(value)", file: file, line: line)
        }
    }

    func testHTMLAndHTMRoutesKeepTurkishTextAndTables() throws {
        let input = try html()
        XCTAssertEqual(FeatureCatalog.formats(for: [input]), FeatureCatalog.macOnlyConversionMatrix["html"])
        XCTAssertEqual(
            FeatureCatalog.formats(for: [root.appendingPathComponent("eski.htm")]),
            FeatureCatalog.macOnlyConversionMatrix["html"])
        for format in ["docx", "pdf", "txt", "md"] { try assertContent(convert(input, format)) }
    }

    func testDOCAndODTRoutesKeepTurkishTextAndTables() throws {
        let source = try html()
        // Build real legacy Word and OpenDocument files with LibreOffice itself.
        for legacy in ["doc", "odt"] {
            let input = try convert(source, legacy)
            XCTAssertEqual(input.pathExtension, legacy)
            let before = try Data(contentsOf: input)
            XCTAssertEqual(
                Set(FeatureCatalog.formats(for: [input])), Set(FeatureCatalog.macOnlyConversionMatrix[legacy] ?? []))
            for format in ["docx", "pdf", "txt"] { try assertContent(convert(input, format)) }
            XCTAssertEqual(try Data(contentsOf: input), before)
        }
    }
}
