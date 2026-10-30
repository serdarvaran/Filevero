import XCTest

@testable import FileveroUpdates

final class PublicUpdateChannelTests: XCTestCase {
    private let info: [String: Any] = [
        "FileveroPublicUpdateRepository": "filevero/filevero",
        "SUFeedURL": "https://github.com/filevero/filevero/releases/latest/download/appcast.xml",
    ]
    private final class NoCredentials: UpdateCredentialStore, @unchecked Sendable {
        func token(for repository: GitHubRepository) throws -> String {
            XCTFail("Anonymous migration read a private token")
            throw UpdateCredentialError.missing
        }
        func save(_ token: String, for repository: GitHubRepository) throws {
            XCTFail("Anonymous migration wrote a credential")
        }
        func remove(for repository: GitHubRepository) throws { XCTFail("Anonymous migration deleted a credential") }
    }
    func testOfficialChannelRequiresExactBundledFeed() {
        XCTAssertNotNil(PublicUpdateChannel(info: info))
        for address in [
            "http://github.com/filevero/filevero/releases/latest/download/appcast.xml",
            "https://github.com/attacker/filevero-app/releases/latest/download/appcast.xml",
            "https://github.com/filevero/filevero/releases/latest/download/appcast.xml?token=x",
        ] {
            var altered = info
            altered["SUFeedURL"] = address
            XCTAssertNil(PublicUpdateChannel(info: altered))
        }
    }
    func testNewUsersAndSavedOfficialChannelDoNotTouchCredentials() async {
        for previous in [nil, "filevero/filevero"] as [String?] {
            let suite = "FileveroPublicChannelTests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if let previous {
                defaults.set(previous, forKey: "FileveroUpdateGitHubRepository")
                defaults.set(true, forKey: "FileveroUpdateGitHubRequiresToken")
                defaults.set(true, forKey: "FileveroUpdateGitHubSavedToken")
            }
            defaults.set("retained", forKey: "history")
            defaults.set(false, forKey: "FileveroUpdateGitHubAutomaticChecks")
            await MainActor.run {
                let updater = AppUpdater(credentials: NoCredentials(), defaults: defaults, info: info)
                XCTAssertNil(updater.repository)
                XCTAssertFalse(updater.requiresToken)
                XCTAssertFalse(updater.hasSavedToken)
                XCTAssertEqual(updater.officialRepository?.slug, "filevero/filevero")
            }
            XCTAssertEqual(defaults.string(forKey: "history"), "retained")
            if previous != nil { XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false) }
        }
    }
    func testUnrelatedCustomChannelIsPreserved() async {
        let suite = "FileveroPublicChannelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("example/custom", forKey: "FileveroUpdateGitHubRepository")
        defaults.set(true, forKey: "FileveroUpdateGitHubRequiresToken")
        await MainActor.run {
            let updater = AppUpdater(credentials: NoCredentials(), defaults: defaults, info: info)
            XCTAssertEqual(updater.repository?.slug, "example/custom")
            XCTAssertTrue(updater.requiresToken)
        }
    }
}
