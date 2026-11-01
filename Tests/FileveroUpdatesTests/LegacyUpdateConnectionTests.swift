import XCTest

@testable import FileveroUpdates

final class LegacyUpdateConnectionTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "LegacyUpdateConnectionTests." + UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testConnectedRepositoryHandsItsAutomaticCheckChoiceBackToSparkle() throws {
        let defaults = try makeDefaults()
        defaults.set("example/custom", forKey: "FileveroUpdateGitHubRepository")
        defaults.set(true, forKey: "FileveroUpdateGitHubRequiresToken")
        defaults.set(false, forKey: "FileveroUpdateGitHubAutomaticChecks")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")

        SparkleUpdateCoordinator.removeLegacyConnection(from: defaults)

        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        for key in SparkleUpdateCoordinator.legacyConnectionKeys { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    func testConnectionThatNeverChangedTheChoiceTurnsAutomaticChecksBackOn() throws {
        let defaults = try makeDefaults()
        defaults.set("example/custom", forKey: "FileveroUpdateGitHubRepository")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")

        SparkleUpdateCoordinator.removeLegacyConnection(from: defaults)

        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, true)
    }

    func testWithoutAConnectionTheUsersSparkleChoiceIsKept() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "SUEnableAutomaticChecks")

        SparkleUpdateCoordinator.removeLegacyConnection(from: defaults)

        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
    }
}
