import CoreGraphics
import XCTest

@testable import FileveroCore

final class OutputNamingTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func image(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url)
        return url
    }

    private func convert(_ inputs: [URL], template: String?, into destination: URL) throws -> [URL] {
        var options = OperationOptions()
        options.outputDirectory = destination
        options.outputNameTemplate = template
        options.revealInFinder = false
        return try ConversionEngine.run(.init(inputs: inputs, operation: .convert("jpg"), options: options))
    }

    func testWithoutTemplateEngineNamesAreUnchanged() throws {
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        let outputs = try convert([image("Deniz.png")], template: nil, into: destination)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Deniz.jpg"])
    }

    func testTemplateNumbersFilesInInputOrderKeepsExtensionAndLeavesSourcesUntouched() throws {
        let inputs = try ["Çiçek.png", "Ağaç.png", "Işık.png"].map(image)
        let before = try inputs.map { try Data(contentsOf: $0) }
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        let outputs = try convert(inputs, template: "Tatil-{n}-{name}", into: destination)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Tatil-1-Çiçek.jpg", "Tatil-2-Ağaç.jpg", "Tatil-3-Işık.jpg"])
        XCTAssertEqual(try inputs.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".png") }.sorted(),
            ["Ağaç.png", "Işık.png", "Çiçek.png"].sorted())
    }

    func testRepeatedAndExistingNamesNeverOverwrite() throws {
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("Rapor.jpg")
        try Data("previous output".utf8).write(to: existing)
        let outputs = try convert([image("A.png"), image("B.png")], template: "Rapor", into: destination)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Rapor 2.jpg", "Rapor 3.jpg"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("previous output".utf8))
    }

    func testInvalidTemplatesFailBeforeAnyOutputIsWritten() throws {
        let input = try image("Kaynak.png")
        let before = try Data(contentsOf: input)
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        for template in [
            "", "   ", "a/b", "a:b", "{unknown}", "{name", "name}", ".{name}", "{name}\n",
            String(repeating: "ş", count: 200),
        ] {
            XCTAssertThrowsError(try convert([input], template: template, into: destination), template) { error in
                guard case FileveroError.invalidInput = error else { return XCTFail("\(template): \(error)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testCounterPaddingDateAndUnicodeNormalization() throws {
        let template = try OutputNameTemplate("{date}_{n}_{name}")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12)))
        let decomposed = "S\u{0327}eker"
        let name = try template.name(for: "\(decomposed).png", index: 3, total: 12, date: date)
        XCTAssertEqual(name, "2026-10-29_03_Şeker.png")
        XCTAssertEqual(name, name.precomposedStringWithCanonicalMapping)
        XCTAssertEqual(try template.name(for: "Klasör", index: 7, total: 7, date: date), "2026-10-29_7_Klasör")
    }

    func testFolderOutputsAreRenamedAsAWholeAndKeepTheirContents() throws {
        let destination = root.appendingPathComponent("Exports", isDirectory: true)
        let transaction = ExportTransaction()
        defer { transaction.cleanUp() }
        let area = try transaction.makeArea(destination: destination)
        let folder = area.directory.appendingPathComponent("Sayfalar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent("Sayfa 001.png")
        try Data("page".utf8).write(to: page)
        try transaction.record([page], in: area)
        let outputs = try transaction.publish(token: .init(), naming: OutputNameTemplate("Arşiv {name}"))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Sayfa 001.png"])
        XCTAssertEqual(outputs.first?.deletingLastPathComponent().lastPathComponent, "Arşiv Sayfalar")
        XCTAssertEqual(try Data(contentsOf: outputs[0]), Data("page".utf8))
    }
}

/// The preview must name files exactly as the queued conversion later does.
final class OutputNamePreviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func image(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url)
        return url
    }
    private func publishedNames(_ inputs: [URL], format: String, template: String?) throws -> [String] {
        var options = OperationOptions()
        options.outputNameTemplate = template
        options.revealInFinder = false
        var state = JobQueueState()
        state.enqueue(inputs, operation: .convert(format), options: options)
        var names: [String] = []
        while let job = state.next {
            let outputs = try job.run(token: .init())
            state.update(job.id, to: .done(outputs))
            let first = try XCTUnwrap(outputs.first)
            names.append(
                first.deletingLastPathComponent() == root
                    ? first.lastPathComponent : first.deletingLastPathComponent().lastPathComponent)
        }
        return names
    }

    func testPreviewMatchesPublishedNamesForExistingFilesAndDuplicates() throws {
        let inputs = try ["Ada.png", "Bora.png", "Çınar.png"].map(image)
        try Data("existing".utf8).write(to: root.appendingPathComponent("Ada.jpg"))
        let plain = try OutputNamePreview.preview(inputs, format: "jpg", template: nil)
        XCTAssertEqual(plain.map(\.status), [.existing, .available, .available])
        XCTAssertEqual(plain.map(\.name), try publishedNames(inputs, format: "jpg", template: nil))

        let shared = try OutputNamePreview.preview(inputs, format: "jpg", template: "Rapor")
        XCTAssertEqual(shared.map(\.status), [.available, .duplicate, .duplicate])
        XCTAssertEqual(shared.map(\.name), ["Rapor.jpg", "Rapor 2.jpg", "Rapor 3.jpg"])
        XCTAssertEqual(shared.map(\.name), try publishedNames(inputs, format: "jpg", template: "Rapor"))

        let numbered = try OutputNamePreview.preview(inputs, format: "webp", template: "{n}-{name}")
        XCTAssertEqual(numbered.map(\.name), ["1-Ada.webp", "2-Bora.webp", "3-Çınar.webp"])
        XCTAssertTrue(numbered.allSatisfy { $0.status == .available })
    }

    func testPreviewNamesRenderedPageFoldersAndRejectsInvalidTemplates() throws {
        let pdf = root.appendingPathComponent("Belge.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Belge - Pages"), withIntermediateDirectories: true)
        let preview = try OutputNamePreview.preview([pdf], format: "png", template: nil)
        XCTAssertEqual(preview.map(\.name), ["Belge - Pages 2"])
        XCTAssertEqual(preview.map(\.status), [.existing])
        XCTAssertEqual(preview.map(\.name), try publishedNames([pdf], format: "png", template: nil))
        XCTAssertThrowsError(try OutputNamePreview.preview([pdf], format: "png", template: "a/b"))
    }
}
