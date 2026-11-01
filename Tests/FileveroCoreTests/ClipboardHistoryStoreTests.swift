import AppKit
import XCTest

@testable import FileveroCore

final class ClipboardHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardStore-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func saved(_ formats: [ClipboardFormat: Data], in store: ClipboardHistoryStore) throws -> ClipboardEntry {
        let entry = ClipboardEntry(capture: formats, sourceApp: "com.apple.TextEdit")
        try store.store(formats, for: entry.id)
        return entry
    }

    func testSaveLoadRoundTripsEntriesAndBlobsWithPrivatePermissions() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let formats: [ClipboardFormat: Data] = [.plainText: Data("hello".utf8), .png: Data([1, 2, 3])]
        let entry = try saved(formats, in: store)
        let history = ClipboardHistory(entries: [entry], bootTime: Date(timeIntervalSince1970: 5))

        try store.save(history)

        XCTAssertEqual(ClipboardHistoryStore(directory: directory).load(), history)
        XCTAssertEqual(store.formats(for: entry), formats)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("history.json")), 0o600)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("blobs/\(entry.id.uuidString).png")), 0o600)
    }

    func testMissingBlobDropsEntry() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let kept = try saved([.plainText: Data("kept".utf8)], in: store)
        let lost = try saved([.plainText: Data("lost".utf8)], in: store)
        try store.save(ClipboardHistory(entries: [kept, lost]))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("blobs/\(lost.id.uuidString).txt"))

        XCTAssertEqual(store.load().entries.map(\.id), [kept.id])
    }

    func testUnreadableIndexFallsBackToTheBackupAndKeepsPins() throws {
        let store = ClipboardHistoryStore(directory: directory)
        var pinned = try saved([.plainText: Data("pinned".utf8)], in: store)
        pinned.pinned = true
        let history = ClipboardHistory(entries: [pinned], bootTime: Date(timeIntervalSince1970: 5))
        try store.save(history)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("history.json"))

        let reopened = ClipboardHistoryStore(directory: directory)
        XCTAssertEqual(reopened.load(), history)
        try reopened.save(ClipboardHistory(entries: [pinned]))
        XCTAssertEqual(reopened.formats(for: pinned), [.plainText: Data("pinned".utf8)])
    }

    func testUnreadableIndexAndBackupRecoverItemsFromTheirSavedData() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let text = try saved([.plainText: Data("text".utf8), .html: Data("<b>text</b>".utf8)], in: store)
        let image = try saved([.png: Data([1, 2, 3])], in: store)
        try store.save(ClipboardHistory(entries: [text, image]))
        for name in ["history.json", "history.backup.json"] {
            try Data("{not json".utf8).write(to: directory.appendingPathComponent(name))
        }

        let reopened = ClipboardHistoryStore(directory: directory)
        let recovered = reopened.load()

        XCTAssertEqual(Set(recovered.entries.map(\.id)), [text.id, image.id])
        let recoveredText = try XCTUnwrap(recovered.entries.first { $0.id == text.id })
        XCTAssertEqual(recoveredText.kind, .richText)
        XCTAssertEqual(recoveredText.digest, text.digest)
        XCTAssertEqual(reopened.formats(for: recoveredText), [.plainText: Data("text".utf8), .html: Data("<b>text</b>".utf8)])
    }

    func testSavingNeverDeletesTheDataOfAnItemStillOnItsWayIn() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let kept = try saved([.plainText: Data("kept".utf8)], in: store)
        try store.save(ClipboardHistory(entries: [kept]))
        let arriving = try saved([.plainText: Data("arriving".utf8)], in: store)

        try store.save(ClipboardHistory(entries: [kept]).togglingPin(kept.id))

        XCTAssertEqual(store.formats(for: arriving), [.plainText: Data("arriving".utf8)])
    }

    func testLoadingRemovesDataNoEntryRefersTo() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let kept = try saved([.plainText: Data("kept".utf8)], in: store)
        try store.save(ClipboardHistory(entries: [kept]))
        let orphan = try saved([.png: Data([9])], in: store)

        XCTAssertEqual(ClipboardHistoryStore(directory: directory).load().entries.map(\.id), [kept.id])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("blobs/\(orphan.id.uuidString).png").path))
    }

    func testDiscardRemovesAnItemsSavedData() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let discarded = try saved([.plainText: Data("late".utf8), .png: Data([1])], in: store)

        try store.discard(discarded.id)

        XCTAssertEqual(store.formats(for: discarded), [:])
    }

    func testSaveDeletesBlobsOfRemovedEntries() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let removed = try saved([.html: Data("<b>x</b>".utf8)], in: store)
        try store.save(ClipboardHistory(entries: [removed]))

        try store.save(ClipboardHistory(entries: []))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("blobs/\(removed.id.uuidString).html").path))
    }

    func testCaptureReadsEveryFormatFromAPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        pasteboard.clearContents()
        pasteboard.setString("cell", forType: .string)
        pasteboard.setString("<table/>", forType: .html)
        pasteboard.setData(Data("{\\rtf1 cell}".utf8), forType: .rtf)
        pasteboard.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        pasteboard.setString("com.microsoft.Excel", forType: .init("org.nspasteboard.source"))

        let read = try XCTUnwrap(ClipboardPasteboardCodec.capture(pasteboard, frontmostApp: "com.apple.finder"))
        XCTAssertNil(read.formats[.png], "TIFF is converted later, off the main thread")
        let capture = ClipboardPasteboardCodec.storable(read)

        XCTAssertEqual(Set(capture.formats.keys), [.plainText, .html, .rtf, .png])
        XCTAssertNil(capture.pendingTIFF)
        XCTAssertEqual(capture.sourceApp, "com.microsoft.Excel")
        XCTAssertNotNil(NSBitmapImageRep(data: try XCTUnwrap(capture.formats[.png])))
    }

    func testWritingRestoresEveryStoredFormatWithMarker() throws {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let formats: [ClipboardFormat: Data] = [
            .plainText: Data("cell".utf8), .html: Data("<table/>".utf8), .rtf: Data("{\\rtf1 cell}".utf8),
            .fileURLs: Data(file.path.utf8),
        ]

        ClipboardPasteboardCodec.write(formats, plainTextOnly: false, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "cell")
        XCTAssertEqual(pasteboard.data(forType: .html), formats[.html])
        XCTAssertEqual(pasteboard.data(forType: .rtf), formats[.rtf])
        XCTAssertEqual(
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path),
            [file.path])
        let restored = try XCTUnwrap(ClipboardPasteboardCodec.capture(pasteboard, frontmostApp: nil))
        XCTAssertTrue(restored.markers.contains(ClipboardHistory.restoreMarker))
        XCTAssertTrue(restored.formats.isEmpty)

        ClipboardPasteboardCodec.write(formats, plainTextOnly: true, to: pasteboard)
        let types = Set(pasteboard.types ?? [])
        XCTAssertTrue(types.isSuperset(of: [.string, NSPasteboard.PasteboardType(ClipboardHistory.restoreMarker)]))
        XCTAssertTrue(types.isDisjoint(with: [.html, .rtf, .png, .fileURL]))
        XCTAssertEqual(pasteboard.string(forType: .string), "cell")
    }

    func testConcealedContentIsNotReadFromThePasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))

        let capture = try XCTUnwrap(ClipboardPasteboardCodec.capture(pasteboard, frontmostApp: nil))

        XCTAssertTrue(capture.formats.isEmpty)
        XCTAssertFalse(ClipboardHistory.shouldRecord(capture, excludedApps: []))
    }

    func testPlainTextPasteOfAnImageKeepsTheImage() {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        ClipboardPasteboardCodec.write([.png: Data([1, 2, 3])], plainTextOnly: true, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3]))
    }
}
