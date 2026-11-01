import XCTest

@testable import FileveroCore

final class FolderWatchScannerTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Watched", isDirectory: true)
    private let start = Date(timeIntervalSince1970: 0)

    private func entry(_ name: String, _ size: Int64, _ second: Double = 0) -> FolderWatchScanner.Entry {
        .init(url: folder.appendingPathComponent(name), state: .init(size: size, modified: start.addingTimeInterval(second)))
    }

    func testNewFilesAreReportedOnceAfterTheyStopChanging() {
        var scanner = FolderWatchScanner(existing: [entry("old.jpg", 10)])
        XCTAssertEqual(scanner.scan([entry("old.jpg", 10), entry("new.jpg", 5)], at: start), [])
        XCTAssertEqual(scanner.scan([entry("old.jpg", 10), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(1)), [])
        XCTAssertEqual(scanner.scan([entry("old.jpg", 10), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(2)), [])
        XCTAssertEqual(
            scanner.scan([entry("old.jpg", 10), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(3)).map(\.lastPathComponent),
            ["new.jpg"])
        XCTAssertEqual(scanner.scan([entry("old.jpg", 10), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(9)), [])
        _ = scanner.scan([entry("old.jpg", 11, 5), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(10))
        XCTAssertEqual(scanner.scan([entry("old.jpg", 11, 5), entry("new.jpg", 9, 1)], at: start.addingTimeInterval(12)).count, 1,
                       "a new version of a known file is processed")
    }

    func testTemporaryAndSystemFilesAreIgnored() {
        for name in [".hidden.jpg", "~$Rapor.docx", "video.mp4.crdownload", "indir.part", "Thumbs.db", ".DS_Store", "a.download"] {
            XCTAssertFalse(FolderWatchScanner.isCandidate(folder.appendingPathComponent(name)), name)
        }
        XCTAssertTrue(FolderWatchScanner.isCandidate(folder.appendingPathComponent("Ekran Görüntüsü.png")))
    }

    func testListingSkipsTheFileveroResultsFolderAndSubfolders() throws {
        let root = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Filevero", isDirectory: true), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Filevero/result.webp"))
        try Data("x".utf8).write(to: root.appendingPathComponent("top.txt"))
        XCTAssertEqual(FolderWatchScanner.list(root)?.map(\.url.lastPathComponent), ["top.txt"])
        XCTAssertNil(FolderWatchScanner.list(root.appendingPathComponent("Missing")), "an unreadable folder is not an empty one")
        XCTAssertEqual(WatchedFolder(path: root, workflowID: UUID()).outputDirectory.lastPathComponent, "Filevero")
    }

    func testWatchedFoldersSurviveEncoding() throws {
        let watched = WatchedFolder(path: folder, workflowID: UUID())
        XCTAssertEqual(try JSONDecoder().decode(WatchedFolder.self, from: JSONEncoder().encode(watched)), watched)
        XCTAssertTrue(watched.isEnabled)
    }
}
