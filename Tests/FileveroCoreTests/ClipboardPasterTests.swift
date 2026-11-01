import AppKit
import XCTest

@testable import FileveroCore

final class ClipboardPasterTests: XCTestCase {
    private let formats: [ClipboardFormat: Data] = [.plainText: Data("hello".utf8), .html: Data("<b>hello</b>".utf8)]

    func testPasterFallsBackToCopyWithoutAccessibility() {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        var posted = false
        let paster = ClipboardPaster(isTrusted: { false }, postCommandV: { posted = true }, activate: { _ in })

        let result = paster.paste(formats, plainTextOnly: false, into: nil, pasteboard: pasteboard)

        XCTAssertEqual(result, .copiedOnly)
        XCTAssertFalse(posted)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertNotNil(pasteboard.data(forType: .html))
    }

    func testPasterActivatesTargetThenPostsCommandV() {
        let pasteboard = NSPasteboard(name: .init("filevero-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        var calls: [String] = []
        let paster = ClipboardPaster(
            isTrusted: { true }, postCommandV: { calls.append("post") }, activate: { _ in calls.append("activate") })

        let result = paster.paste(formats, plainTextOnly: true, into: nil, pasteboard: pasteboard)

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(calls, ["activate", "post"])
        XCTAssertNil(pasteboard.data(forType: .html))
    }
}
