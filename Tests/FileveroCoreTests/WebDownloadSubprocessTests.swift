import XCTest

@testable import FileveroCore

final class WebDownloadSubprocessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testReturnsStandardOutput() async throws {
        let data = try await WebDownloadSubprocess.run(shell, ["-c", "printf 'metadata'"], token: .init(), timeout: 5)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "metadata")
    }

    func testFailureUsesFriendlyMessageWithoutSecrets() async {
        do {
            _ = try await WebDownloadSubprocess.run(
                shell, ["-c", "printf 'ERROR 403: https://example.org/a?token=secret' >&2; exit 1"], token: .init(),
                timeout: 5)
            XCTFail("Expected a failure")
        } catch FileveroError.failed(let message) {
            XCTAssertFalse(message.contains("secret"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutStopsTheWholeProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let start = Date()
        do {
            _ = try await WebDownloadSubprocess.run(
                shell, ["-c", "(sleep 1.5; touch '\(marker.path)') & sleep 30"], token: .init(), timeout: 0.2)
            XCTFail("Expected a timeout")
        } catch FileveroError.failed(let message) {
            XCTAssertEqual(message, "The site took too long to respond. Try the link again.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A child of the helper outlived it")
    }

    func testCancellationDuringRunThrowsCancelled() async {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let start = Date()
        do {
            _ = try await WebDownloadSubprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], token: token, timeout: 60)
            XCTFail("Expected cancellation")
        } catch FileveroError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedOutputIsRejected() async {
        do {
            _ = try await WebDownloadSubprocess.run(
                shell, ["-c", "head -c 9000000 /dev/zero; sleep 30"], token: .init(), timeout: 60)
            XCTFail("Expected an overflow failure")
        } catch FileveroError.failed(let message) {
            XCTAssertEqual(message, "The site returned too much metadata. Try an individual media link.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReturnsPromptlyAfterExitAndKeepsProgressParsing() async throws {
        let events = OperationProgressTests.Events()
        let start = Date()
        _ = try await WebDownloadSubprocess.run(
            shell, ["-c", "printf 'FILEVERO_PROGRESS: 50%%\\nFILEVERO_STAGE:Finishing media…\\n'"], token: .init(),
            timeout: 5, progress: { events.add($0, $1) })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(events.values.map(\.0), [0.5, OperationProgress.indeterminate])
        XCTAssertEqual(events.values.map(\.1), ["Downloading media…", "Finishing media…"])
    }
}
