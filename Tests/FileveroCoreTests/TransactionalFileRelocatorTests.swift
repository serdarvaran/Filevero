import XCTest

@testable import FileveroCore

final class FileMoveTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ text: String = "x", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testSwappedNamesAndCaseOnlyRenameApplyAndUndo() throws {
        let a = try file("a.txt", "A")
        let b = try file("b.txt", "B")
        let c = try file("c.txt", "C")
        let applied = try FileMoveEngine.apply(
            [
                FileMove(source: a, destination: b), FileMove(source: b, destination: a),
                FileMove(source: c, destination: folder.appendingPathComponent("C.txt")),
            ], title: "Rename")
        XCTAssertEqual(names(), ["C.txt", "a.txt", "b.txt"])
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "A")
        try FileMoveEngine.undo(applied)
        XCTAssertEqual(names(), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A")
    }

    func testRefusesExistingTargetAndLeavesEverythingInPlace() throws {
        let a = try file("a.txt")
        let b = try file("b.txt")
        _ = try file("taken.txt")
        XCTAssertThrowsError(
            try FileMoveEngine.apply(
                [
                    FileMove(source: a, destination: folder.appendingPathComponent("new.txt")),
                    FileMove(source: b, destination: folder.appendingPathComponent("taken.txt")),
                ], title: "Rename"))
        XCTAssertEqual(names(), ["a.txt", "b.txt", "taken.txt"])
    }

    func testUndoRefusesWhenARenamedFileIsGone() throws {
        let a = try file("a.txt")
        let target = folder.appendingPathComponent("z.txt")
        let applied = try FileMoveEngine.apply([FileMove(source: a, destination: target)], title: "Rename")
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try FileMoveEngine.undo(applied))
    }

    func testRenamePreviewNumbersReplacesAndReportsConflicts() throws {
        let first = try file("IMG_001.JPG")
        let second = try file("IMG_002.JPG")
        _ = try file("Trip 1.JPG")
        var options = RenameOptions()
        options.template = "Trip {n}"
        options.startNumber = 1
        let rows = BatchRename.preview([first, second], options: options)
        XCTAssertEqual(rows.map(\.name), ["Trip 1.JPG", "Trip 2.JPG"])
        XCTAssertEqual(rows[0].status, .conflict("A file with this name exists."))
        XCTAssertThrowsError(try BatchRename.plan(rows))

        options.template = "{name}"
        options.find = "img_"
        options.replace = "Photo "
        options.letterCase = .lower
        let replaced = BatchRename.preview([first, second], options: options)
        XCTAssertEqual(replaced.map(\.name), ["photo 001.JPG", "photo 002.JPG"])
        XCTAssertEqual(try BatchRename.plan(replaced).count, 2)

        options = RenameOptions()
        options.template = "same"
        XCTAssertEqual(
            BatchRename.preview([first, second], options: options).map(\.status),
            [.conflict("Another file gets this name."), .conflict("Another file gets this name.")])
        options.template = "{name}"
        options.find = "IMG"
        options.replace = "a/b"
        if case .conflict = BatchRename.preview([first], options: options)[0].status {
        } else {
            XCTFail("A slash must be rejected")
        }
    }

    func testRenameUsesDateTakenAndKeepsUnchangedFilesOut() throws {
        let photo = try file("note.txt")
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 3, day: 9, hour: 12)
            .date!
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: photo.path)
        var options = RenameOptions()
        options.template = "{date} {name}"
        XCTAssertEqual(BatchRename.preview([photo], options: options).first?.name, "2024-03-09 note.txt")
        options.template = "{name}"
        XCTAssertEqual(BatchRename.preview([photo], options: options).first?.status, .unchanged)
    }

    func testOrganizeByMonthAndKindThenUndoRemovesCreatedFolders() throws {
        let photo = try file("photo.png")
        let doc = try file("notes.txt")
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2023, month: 11, day: 2).date!
        for url in [photo, doc] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        XCTAssertEqual(
            FileOrganizer.plan([photo], mode: .month).first?.destination.deletingLastPathComponent().lastPathComponent,
            "2023-11")
        let applied = try FileMoveEngine.apply(
            FileOrganizer.plan([photo, doc], mode: .type, language: "tr"), title: "Sort")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("Görseller/photo.png").path),
            "\(names())")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("Belgeler/notes.txt").path),
            "\(names())")
        try FileMoveEngine.undo(applied)
        XCTAssertEqual(names(), ["notes.txt", "photo.png"])
    }

    func testFolderContentsDuplicatesAndArchive() throws {
        let inner = folder.appendingPathComponent("Album", isDirectory: true)
        let one = try file("one.txt", "same", in: inner)
        let _ = try file("Deep/two.txt", "same", in: inner)
        let _ = try file(".hidden", "same", in: inner)
        let _ = try file("other.txt", "different", in: inner)
        XCTAssertEqual(
            try FolderContents.files(in: [inner], recursive: false).map(\.lastPathComponent), ["one.txt", "other.txt"])
        XCTAssertEqual(try FolderContents.files(in: [inner], recursive: true).count, 3)
        let groups = try DuplicateFinder.groups(in: [inner])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.lastPathComponent)), ["one.txt", "two.txt"])

        var options = OperationOptions()
        options.revealInFinder = false
        let zip = try ConversionEngine.run(
            ConversionRequest(inputs: [inner, one], operation: .tool(.createArchive), options: options))
        XCTAssertEqual(zip.map(\.lastPathComponent), ["Archive.zip"])
        let listing = String(
            decoding: try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-1", zip[0].path]).output,
            as: UTF8.self)
        XCTAssertTrue(listing.contains("Album/Deep/two.txt"), listing)
        XCTAssertTrue(listing.contains("one.txt"), listing)
    }

    func testOrganizingToolsAllowFolders() throws {
        let inner = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertEqual(FeatureCatalog.organizingTools(for: [inner]), [.renameFiles, .findDuplicates, .createArchive])
        XCTAssertEqual(
            FeatureCatalog.organizingTools(for: [try file("a.txt")]), [.renameFiles, .organizeFiles, .createArchive])
        XCTAssertEqual(FeatureCatalog.tools(for: [inner]), [])
    }

    func testOverlappingSelectionNeverReportsAFileAsItsOwnCopy() throws {
        let inner = folder.appendingPathComponent("Album", isDirectory: true)
        let only = try file("only.jpg", "one of a kind", in: inner)
        XCTAssertEqual(
            try FolderContents.files(in: [inner, only, inner], recursive: true).map {
                $0.resolvingSymlinksInPath().path
            }, [only.resolvingSymlinksInPath().path])
        XCTAssertEqual(try DuplicateFinder.groups(in: [inner, only]), [])
        let link = inner.appendingPathComponent("hard link.jpg")
        try FileManager.default.linkItem(at: only, to: link)
        XCTAssertEqual(try DuplicateFinder.groups(in: [inner]), [], "A hard link is the same file, not a copy")
    }

    func testUnusualExistingNamesStayRenamableAndUndoable() throws {
        let colon = try file("Rapor 3:4.pdf")
        let other = try file("notes.txt")
        let dotted = try file(".env.x")
        var options = RenameOptions()
        options.find = "notes"
        options.replace = "Notlar"
        let rows = BatchRename.preview([colon, other], options: options)
        XCTAssertEqual(rows.map(\.status), [.unchanged, .ready])
        XCTAssertEqual(try BatchRename.plan(rows).count, 1)
        XCTAssertEqual(FileOrganizer.plan([colon], mode: .year).count, 1)
        _ = try FileMoveEngine.apply(FileOrganizer.plan([colon], mode: .year), title: "Sort")

        let applied = try FileMoveEngine.apply(
            [FileMove(source: dotted, destination: folder.appendingPathComponent("env.x"))], title: "Rename")
        try FileMoveEngine.undo(applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dotted.path))
    }

    func testSelectionArchiveUsesTheChosenFormat() throws {
        let album = folder.appendingPathComponent("Album", isDirectory: true)
        _ = try file("a.txt", "kept", in: album)
        for (format, name) in [("7z", "Album.7z"), ("gz", "Album.tar.gz"), ("bz2", "Album.tar.bz2"), ("xz", "Album.tar.xz")] {
            var options = OperationOptions()
            options.revealInFinder = false
            options.archiveFormat = format
            let archive = try ConversionEngine.run(
                ConversionRequest(inputs: [album], operation: .tool(.createArchive), options: options))
            XCTAssertEqual(archive.map(\.lastPathComponent), [name])
            let extracted = folder.appendingPathComponent("\(format) contents", isDirectory: true)
            try ArchiveCodec.extract(archive[0], into: extracted, token: .init())
            XCTAssertEqual(
                try String(contentsOf: extracted.appendingPathComponent("Album/a.txt"), encoding: .utf8), "kept")
        }
    }

    func testZipOfADottedFolderKeepsItsWholeName() throws {
        let album = folder.appendingPathComponent("Photos 2024.05", isDirectory: true)
        _ = try file("a.txt", in: album)
        var options = OperationOptions()
        options.revealInFinder = false
        let zip = try ConversionEngine.run(
            ConversionRequest(inputs: [album], operation: .tool(.createArchive), options: options))
        XCTAssertEqual(zip.map(\.lastPathComponent), ["Photos 2024.05.zip"])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".filevero-zip") },
            "The staging folder is removed")
    }
}
