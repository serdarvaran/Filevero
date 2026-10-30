import XCTest

@testable import FileveroCore

final class UnreadableDefaultsBackupTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UnreadableDefaultsBackupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDecodesReadableValueWithoutBackup() throws {
        defaults.set(try JSONEncoder().encode(["a", "b"]), forKey: "items")

        XCTAssertEqual(defaults.decodePreservingUnreadable([String].self, forKey: "items"), ["a", "b"])
        XCTAssertNil(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items")))
    }

    func testMissingValueReturnsNilWithoutBackup() {
        XCTAssertNil(defaults.decodePreservingUnreadable([String].self, forKey: "items"))
        XCTAssertNil(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items")))
    }

    func testUnreadableValueSurvivesTheNextSave() throws {
        let old = Data(#"[{"legacy":true}]"#.utf8)
        defaults.set(old, forKey: "items")

        XCTAssertNil(defaults.decodePreservingUnreadable([String].self, forKey: "items"))
        defaults.set(try JSONEncoder().encode(["new"]), forKey: "items")

        XCTAssertEqual(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items")), old)
    }

    func testRepeatedFailureDoesNotDuplicateBackup() {
        let old = Data("not json".utf8)
        defaults.set(old, forKey: "items")

        _ = defaults.decodePreservingUnreadable([String].self, forKey: "items")
        _ = defaults.decodePreservingUnreadable([String].self, forKey: "items")

        XCTAssertEqual(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items")), old)
        XCTAssertNil(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items", index: 1)))
    }

    func testDifferentUnreadableValueKeepsEarlierBackup() {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        defaults.set(first, forKey: "items")
        _ = defaults.decodePreservingUnreadable([String].self, forKey: "items")
        defaults.set(second, forKey: "items")

        _ = defaults.decodePreservingUnreadable([String].self, forKey: "items")

        XCTAssertEqual(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items")), first)
        XCTAssertEqual(defaults.data(forKey: UserDefaults.unreadableBackupKey(for: "items", index: 1)), second)
    }
}
