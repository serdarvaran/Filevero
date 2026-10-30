import CoreGraphics
import XCTest

@testable import FileveroCore

final class WindowArrangementTests: XCTestCase {
    // A Retina laptop work area and an external display placed to its left, higher up.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let external = CGRect(x: -2560, y: 200, width: 2560, height: 1415)

    func testMovingToAnotherDisplayKeepsRelativePlacementAndFits() {
        let leftHalf = CGRect(x: 0, y: 0, width: 756, height: 944)
        XCTAssertEqual(
            WindowGeometry.move(leftHalf, from: laptop, to: external),
            CGRect(x: -2560, y: 200, width: 1280, height: 1415))
        let centered = CGRect(x: 378, y: 236, width: 756, height: 472)
        let moved = WindowGeometry.move(centered, from: laptop, to: external)
        XCTAssertEqual(moved.midX, external.midX, accuracy: 0.5)
        XCTAssertEqual(moved.midY, external.midY, accuracy: 0.5)
        XCTAssertTrue(
            external.contains(
                WindowGeometry.move(CGRect(x: 1400, y: 900, width: 500, height: 300), from: laptop, to: external)))
    }

    func testNextDisplayFollowsReadingOrderAndNeedsTwoDisplays() {
        XCTAssertEqual(WindowGeometry.display(after: laptop, in: [laptop, external]), external)
        XCTAssertEqual(WindowGeometry.display(after: external, in: [laptop, external]), laptop)
        XCTAssertNil(WindowGeometry.display(after: laptop, in: [laptop]))
        XCTAssertEqual(
            WindowGeometry.display(for: CGRect(x: -400, y: 300, width: 300, height: 200), in: [laptop, external]),
            external)
    }

    func testFramesFromDisconnectedDisplaysAreBroughtOnScreen() {
        let saved = CGRect(x: -2000, y: 400, width: 1800, height: 1200)
        let clamped = WindowGeometry.clamp(saved, to: [laptop])
        XCTAssertTrue(laptop.contains(clamped))
        XCTAssertEqual(clamped.size, CGSize(width: 1512, height: 944))
        let visible = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertEqual(WindowGeometry.clamp(visible, to: [laptop, external]), visible)
        let straddling = CGRect(x: 1300, y: 100, width: 600, height: 400)
        XCTAssertEqual(WindowGeometry.clamp(straddling, to: [laptop]), CGRect(x: 912, y: 100, width: 600, height: 400))
    }

    func testLayoutMatchesTitlesFirstThenRemainingWindowsInOrder() throws {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 10, y: 0, width: 10, height: 10)
        let c = CGRect(x: 20, y: 0, width: 10, height: 10)
        let layout = WindowLayout(
            name: "Yazı",
            windows: [
                .init(bundleID: "com.apple.Safari", title: "Rapor — Çalışma", frame: a),
                .init(bundleID: "com.apple.Safari", title: "Haberler", frame: b),
                .init(bundleID: "com.apple.Notes", title: "", frame: c),
            ])
        let open = [
            ("com.apple.Safari", "Yeni sekme"), ("com.apple.Safari", "Rapor — Çalışma"), ("com.apple.Notes", "Notlar"),
            ("com.apple.TextEdit", "Belge"),
        ]
        let assigned = layout.assignments(for: open.map { (bundleID: $0.0, title: $0.1) })
        XCTAssertEqual(assigned[1]?.frame, a)
        XCTAssertEqual(assigned[0]?.frame, b)
        XCTAssertEqual(assigned[2]?.frame, c)
        XCTAssertNil(assigned[3])
        let decoded = try JSONDecoder().decode(WindowLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
    }
}
