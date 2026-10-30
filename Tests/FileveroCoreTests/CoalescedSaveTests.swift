import XCTest

@testable import FileveroCore

@MainActor
final class CoalescedSaveTests: XCTestCase {
    func testBurstOfRequestsProducesOneSave() async throws {
        var saves = 0
        let save = CoalescedSave(interval: .milliseconds(50)) { saves += 1 }
        for _ in 0..<1_000 { save.schedule() }
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(save.hasPendingSave)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(saves, 1)
        XCTAssertFalse(save.hasPendingSave)
    }

    func testRequestAfterSaveSchedulesAnotherSave() async throws {
        var saves = 0
        let save = CoalescedSave(interval: .milliseconds(20)) { saves += 1 }
        save.schedule()
        try await Task.sleep(nanoseconds: 200_000_000)
        save.schedule()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(saves, 2)
    }

    func testFlushWritesPendingStateImmediatelyAndOnlyOnce() async throws {
        var saves = 0
        let save = CoalescedSave(interval: .milliseconds(50)) { saves += 1 }
        save.schedule()

        save.flush()
        XCTAssertEqual(saves, 1)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saves, 1)
    }

    func testFlushWithoutPendingRequestDoesNotSave() {
        var saves = 0
        let save = CoalescedSave(interval: .milliseconds(50)) { saves += 1 }

        save.flush()

        XCTAssertEqual(saves, 0)
    }
}
