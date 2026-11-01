import XCTest

@testable import FileveroCore

final class ClipboardActionsTests: XCTestCase {
    func testCaseChangesFollowTheInterfaceLanguage() {
        XCTAssertEqual(ClipboardAction.uppercase.transform("istanbul ılık", language: "tr"), "İSTANBUL ILIK")
        XCTAssertEqual(ClipboardAction.uppercase.transform("istanbul", language: "en"), "ISTANBUL")
        XCTAssertEqual(ClipboardAction.lowercase.transform("İSTANBUL IŞIK", language: "tr"), "istanbul ışık")
        XCTAssertEqual(ClipboardAction.titleCase.transform("iZMİR ve  ılgaz\ndağı", language: "tr"), "İzmir Ve  Ilgaz\nDağı")
    }

    func testTidyingWhitespaceKeepsParagraphsButDropsTrailingSpacesAndExtraBlankLines() {
        let messy = "  \n\nBaşlık   \r\n\r\n\r\n\tGövde satırı \t\n\n\n"
        XCTAssertEqual(ClipboardAction.tidyWhitespace.transform(messy, language: "en"), "Başlık\n\n\tGövde satırı")
    }

    func testJSONIsIndentedInItsOriginalKeyOrderAndInvalidJSONIsRefused() {
        let json = #"{"ad":"Ayşe","liste":[1,2,{}],"boş":[], "x":"a\"b, {c}"}"#
        XCTAssertEqual(
            ClipboardAction.formatJSON.transform(json, language: "en"),
            "{\n  \"ad\": \"Ayşe\",\n  \"liste\": [\n    1,\n    2,\n    {}\n  ],\n  \"boş\": [],\n  \"x\": \"a\\\"b, {c}\"\n}")
        XCTAssertNil(ClipboardAction.formatJSON.transform("{ad: 1}", language: "en"))
        XCTAssertEqual(
            ClipboardAction.formatJSON.transform("{\"a\":\"\u{301}x, y\",\"b\":[1]}", language: "en"),
            "{\n  \"a\": \"\u{301}x, y\",\n  \"b\": [\n    1\n  ]\n}", "a combining mark after a quote stays inside the string")
    }

    func testActionsOfferedForEachKind() {
        XCTAssertEqual(
            ClipboardAction.available(for: .text),
            [.uppercase, .lowercase, .titleCase, .tidyWhitespace, .formatJSON, .qrCode])
        XCTAssertEqual(ClipboardAction.available(for: .link), [.qrCode])
        XCTAssertEqual(ClipboardAction.available(for: .image), [.savePNG, .saveJPG])
        XCTAssertEqual(ClipboardAction.available(for: .file), [])
    }

    func testQRCodeImageDecodesBackToTheCopiedText() throws {
        let text = "https://filevero.app/indir?dil=tr&ş=1"
        let png = try XCTUnwrap(ClipboardAction.qrCodePNG(for: text))
        let folder = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("QR.png")
        try png.write(to: file)
        XCTAssertEqual(try BarcodeScannerEngine.scan([file]).results.map(\.text), [text])
        XCTAssertNil(ClipboardAction.qrCodePNG(for: String(repeating: "ş", count: 3000)))
    }
    func testSavingAClipboardImageWritesANewFileInTheChosenFormat() throws {
        let folder = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try XCTUnwrap(ClipboardAction.qrCodePNG(for: "Filevero", size: 120))
        let date = Date(timeIntervalSince1970: 0)
        let first = try ClipboardImageExport.save(png, as: "jpg", in: folder, date: date)
        let second = try ClipboardImageExport.save(png, as: "jpg", in: folder, date: date)
        XCTAssertEqual(first.pathExtension, "jpg")
        XCTAssertNotEqual(first, second)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        XCTAssertEqual(first.lastPathComponent, "Clipboard Image \(formatter.string(from: date)).jpg")
        XCTAssertEqual(second.lastPathComponent, "Clipboard Image \(formatter.string(from: date)) 2.jpg")
        XCTAssertEqual(try ImageEngine.load(first).width, try ImageEngine.load(second).width)
        XCTAssertEqual(try ClipboardImageExport.save(png, as: "png", in: folder).pathExtension, "png")
        XCTAssertThrowsError(try ClipboardImageExport.save(nil, as: "png", in: folder))
    }
}
