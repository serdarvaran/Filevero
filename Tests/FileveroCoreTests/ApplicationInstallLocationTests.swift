import XCTest

@testable import FileveroCore

final class ApplicationInstallLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func folder(_ path: String, writable: Bool = true) -> String? {
        ApplicationInstallLocation.installFolder(
            for: URL(fileURLWithPath: path), home: home, systemApplicationsWritable: writable
        )?.path
    }

    func testInstalledCopiesStayWhereTheyAre() {
        XCTAssertNil(folder("/Applications/Filevero.app"))
        XCTAssertNil(folder("/Applications/Utilities/Filevero.app"))
        XCTAssertNil(folder("/Users/someone/Applications/Filevero.app"))
    }

    func testDownloadsAndDiskImagesMoveToApplications() {
        XCTAssertEqual(folder("/Users/someone/Downloads/Filevero.app"), "/Applications")
        XCTAssertEqual(folder("/Volumes/Filevero/Filevero.app"), "/Applications")
    }

    func testUserApplicationsIsUsedWhenTheSystemFolderIsNotWritable() {
        XCTAssertEqual(folder("/Users/someone/Desktop/Filevero.app", writable: false), "/Users/someone/Applications")
    }

    func testSimilarlyNamedFoldersAreNotTreatedAsApplications() {
        XCTAssertEqual(folder("/Applications Old/Filevero.app"), "/Applications")
        XCTAssertEqual(folder("/Users/someone/ApplicationsBackup/Filevero.app"), "/Applications")
    }

    func testDevelopmentBinariesAreIgnored() {
        XCTAssertNil(folder("/Users/someone/Filevero/.build/release"))
    }

    func testTranslocatedPathsAreDetected() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1A2B/d/Filevero.app")
        XCTAssertTrue(ApplicationInstallLocation.isTranslocated(translocated))
        XCTAssertFalse(ApplicationInstallLocation.isTranslocated(URL(fileURLWithPath: "/Applications/Filevero.app")))
    }
}
