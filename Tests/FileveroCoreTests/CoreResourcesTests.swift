import XCTest

@testable import FileveroCore

final class CoreResourcesTests: XCTestCase {
    func testPackagedAppFindsResourcesInContentsResources() throws {
        var source = try XCTUnwrap(CoreResources.url(forResource: "Turkish", withExtension: "json"))
        while source.pathExtension != "bundle" { source.deleteLastPathComponent() }
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.copyItem(
            at: source, to: resources.appendingPathComponent(CoreResources.bundleName, isDirectory: true)
        )

        let bundle = try XCTUnwrap(CoreResources.bundle(in: resources))
        XCTAssertNotNil(bundle.url(forResource: "Turkish", withExtension: "json", subdirectory: "Resources"))
        XCTAssertNotNil(bundle.url(forResource: "LatinWords", withExtension: "json", subdirectory: "Resources"))
    }

    func testMissingResourceBundleIsNotAnError() {
        XCTAssertNil(CoreResources.bundle(in: FileManager.default.temporaryDirectory))
        XCTAssertNil(CoreResources.bundle(in: nil))
    }

    func testTurkishCatalogLoads() {
        XCTAssertEqual(AppLocalization.turkish["Not Now"], "Şimdi değil")
    }
}
