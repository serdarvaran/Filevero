import XCTest

@testable import FileveroUpdates

final class UpdateConfigurationTests: XCTestCase {
    private var info: [String: Any] {
        [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        ]
    }

    func testUnconfiguredBuildCannotStartNetworkUpdates() {
        XCTAssertThrowsError(try UpdateConfiguration(info: [:])) {
            XCTAssertEqual($0 as? UpdateConfiguration.ConfigurationError, .notConfigured)
        }
    }
    func testSigningKeyWithoutAFeedDoesNotStartUpdates() {
        var candidate = info
        candidate.removeValue(forKey: "SUFeedURL")
        XCTAssertThrowsError(try UpdateConfiguration(info: candidate)) {
            XCTAssertEqual($0 as? UpdateConfiguration.ConfigurationError, .missingFeed)
        }
    }
    func testHTTPSAndPinnedEd25519Key() throws {
        let configuration = try UpdateConfiguration(info: info)
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.example.com/appcast.xml")
        XCTAssertEqual(Data(base64Encoded: configuration.publicKey)?.count, 32)
    }
    func testRejectsUntrustedFeedAddresses() {
        for address in [
            "http://updates.example.com/feed", "file:///tmp/appcast.xml", "https://user:password@example.com/feed",
            "https://example.com/feed#fragment", "appcast.xml",
        ] {
            var candidate = info
            candidate["SUFeedURL"] = address
            XCTAssertThrowsError(try UpdateConfiguration(info: candidate), address)
        }
    }
    func testDevelopmentHTTPExceptionIsLimitedToLoopback() throws {
        for address in [
            "http://127.0.0.1:8765/appcast.xml", "http://localhost:8765/appcast.xml", "http://[::1]:8765/appcast.xml",
        ] {
            var candidate = info
            candidate["SUFeedURL"] = address
            XCTAssertThrowsError(try UpdateConfiguration(info: candidate))
            candidate["FileveroLocalUpdateFeed"] = true
            XCTAssertNoThrow(try UpdateConfiguration(info: candidate))
        }
        for address in [
            "http://192.168.1.2/feed", "http://localhost.example.com/feed", "http://127.0.0.1.example.com/feed",
        ] {
            var candidate = info
            candidate["FileveroLocalUpdateFeed"] = true
            candidate["SUFeedURL"] = address
            XCTAssertThrowsError(try UpdateConfiguration(info: candidate))
        }
    }
    func testRejectsMalformedAndIncorrectLengthSigningKeys() {
        for key in [
            "not-a-key", Data(repeating: 1, count: 31).base64EncodedString(),
            Data(repeating: 1, count: 64).base64EncodedString(),
        ] {
            var candidate = info
            candidate["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration(info: candidate))
        }
    }
    func testBothFeedAndArchiveVerificationAreRequired() {
        for flag in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var candidate = info
            candidate[flag] = false
            XCTAssertThrowsError(try UpdateConfiguration(info: candidate)) {
                XCTAssertEqual($0 as? UpdateConfiguration.ConfigurationError, .missingVerification)
            }
        }
    }

    func testShippedAppChecksForUpdatesAutomaticallyByDefault() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    }
}
