import XCTest

@testable import FileveroCore

final class ExecutionPipelineAsyncTests: XCTestCase {
    func testRunAsyncReturnsCapturedOutput() async throws {
        let result = try await ExecutionPipeline.runAsync(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'out'; printf 'err' >&2"])
        XCTAssertEqual(result.text, "out")
        XCTAssertEqual(result.errorText, "err")
    }

    func testRunAsyncReportsNonZeroExitWithDiagnostic() async {
        do {
            _ = try await ExecutionPipeline.runAsync(
                URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'broken input' >&2; exit 3"])
            XCTFail("Expected a failure")
        } catch FileveroError.failed(let message) {
            XCTAssertEqual(message, "broken input")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellingTokenTerminatesRunningProcess() async {
        let token = CancellationToken()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        do {
            _ = try await ExecutionPipeline.runAsync(URL(fileURLWithPath: "/bin/sleep"), ["30"], token: token)
            XCTFail("Expected cancellation")
        } catch FileveroError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellingTaskTerminatesRunningProcess() async {
        let started = Date()
        let task = Task {
            try await ExecutionPipeline.runAsync(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch FileveroError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAlreadyCancelledTokenDoesNotLaunch() async {
        let token = CancellationToken()
        token.cancel()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await ExecutionPipeline.runAsync(
                URL(fileURLWithPath: "/usr/bin/touch"), [marker.path], token: token)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
