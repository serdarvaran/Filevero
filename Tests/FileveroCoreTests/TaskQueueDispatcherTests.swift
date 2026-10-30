import CoreGraphics
import XCTest

@testable import FileveroCore

final class JobQueueTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func image(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url)
        return url
    }
    private func options(_ directory: String, template: String? = nil) -> OperationOptions {
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent(directory, isDirectory: true)
        options.outputNameTemplate = template
        options.revealInFinder = false
        return options
    }
    private func runAll(_ state: inout JobQueueState) {
        while let job = state.next {
            state.update(job.id, to: .running)
            do { state.update(job.id, to: .done(try job.run(token: .init()))) } catch {
                state.update(job.id, to: .failed(error.localizedDescription))
            }
        }
    }

    func testSplitsPerFileWorkButKeepsCombiningToolsAsOneJob() throws {
        let files = (1...3).map { root.appendingPathComponent("\($0).png") }
        var state = JobQueueState()
        let batch = state.enqueue(files, operation: .convert("jpg"), options: .init())
        XCTAssertEqual(state.jobs(in: batch).map(\.inputs), files.map { [$0] })
        XCTAssertEqual(
            state.jobs(in: batch).map(\.options.outputSequence), (1...3).map { OutputSequence(index: $0, total: 3) })
        let merged = state.enqueue(files, operation: .tool(.mergePDF), options: .init())
        XCTAssertEqual(state.jobs(in: merged).map(\.inputs), [files])
        XCTAssertNil(state.jobs(in: merged)[0].options.outputSequence)
        let single = state.enqueue([files[0]], operation: .tool(.compress), options: .init())
        XCTAssertNil(state.jobs(in: single)[0].options.outputSequence)
    }

    func testOperationsSurviveStorageAndUnknownOnesAreRejected() {
        for operation: FileveroCore.Operation in [.convert("webp"), .tool(.splitPDF)] {
            XCTAssertEqual(FileveroCore.Operation(storageKey: operation.storageKey)?.storageKey, operation.storageKey)
        }
        for key in ["", "convert:", "tool:notATool", "resize:jpg"] {
            XCTAssertNil(FileveroCore.Operation(storageKey: key), key)
        }
    }

    func testOneBrokenFileFailsAloneWhileOthersPublishAndSourcesStayUntouched() throws {
        let good = try image("Bir.png")
        let second = try image("Üç.png")
        let broken = root.appendingPathComponent("Bozuk.png")
        try Data("not an image".utf8).write(to: broken)
        let before = try [good, broken, second].map { try Data(contentsOf: $0) }
        var state = JobQueueState()
        let batch = state.enqueue([good, broken, second], operation: .convert("jpg"), options: options("Out"))
        runAll(&state)
        let jobs = state.jobs(in: batch)
        guard case .done(let first) = jobs[0].status, case .failed = jobs[1].status,
            case .done(let third) = jobs[2].status
        else { return XCTFail("\(jobs.map(\.status))") }
        XCTAssertEqual((first + third).map(\.lastPathComponent), ["Bir.jpg", "Üç.jpg"])
        XCTAssertTrue(state.isFinished(batch))
        XCTAssertEqual(try [good, broken, second].map { try Data(contentsOf: $0) }, before)
    }

    func testCancellingStopsWaitingJobsAndARunningJobPublishesNothing() throws {
        let inputs = try ["A.png", "B.png", "C.png"].map(image)
        var state = JobQueueState()
        let batch = state.enqueue(inputs, operation: .convert("jpg"), options: options("Out"))
        let running = try XCTUnwrap(state.next)
        state.update(running.id, to: .running)
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try running.run(token: token))
        state.update(running.id, to: .cancelled)
        state.cancelWaiting()
        XCTAssertEqual(state.jobs(in: batch).map(\.status), [.cancelled, .cancelled, .cancelled])
        XCTAssertNil(state.next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Out/A.jpg").path))

        state.retry(state.jobs(in: batch)[1].id)
        XCTAssertEqual(state.jobs(in: batch).map(\.status), [.cancelled, .waiting, .cancelled])
        state.retryAll()
        runAll(&state)
        XCTAssertTrue(
            state.jobs(in: batch).allSatisfy {
                if case .done = $0.status { return true }
                return false
            })
        state.clearFinished()
        XCTAssertTrue(state.jobs.isEmpty)
    }

    func testRelaunchMarksUnfinishedJobsInterruptedAndKeepsResults() throws {
        let inputs = [
            root.appendingPathComponent("a.png"), root.appendingPathComponent("b.png"),
            root.appendingPathComponent("c.png"),
        ]
        var state = JobQueueState()
        state.enqueue(inputs, operation: .convert("jpg"), options: .init())
        state.update(state.jobs[0].id, to: .done([root.appendingPathComponent("a.jpg")]))
        state.update(state.jobs[1].id, to: .running)
        let restored = try JSONDecoder().decode(JobQueueState.self, from: JSONEncoder().encode(state)).restored()
        XCTAssertEqual(
            restored.jobs.map(\.status), [.done([root.appendingPathComponent("a.jpg")]), .interrupted, .interrupted])
        XCTAssertEqual(restored.jobs.map(\.operation?.storageKey), ["convert:jpg", "convert:jpg", "convert:jpg"])
        XCTAssertNil(restored.next)
    }

    func testSavedQueueNeverContainsPasswords() throws {
        var options = OperationOptions()
        options.password = "gizli-şifre-123"
        var state = JobQueueState()
        state.enqueue([root.appendingPathComponent("Arşiv.zip")], operation: .tool(.extractArchive), options: options)
        XCTAssertEqual(state.jobs[0].options.password, "gizli-şifre-123")
        let data = try JSONEncoder().encode(state)
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "gizli"))
        XCTAssertEqual(try JSONDecoder().decode(JobQueueState.self, from: data).jobs[0].options.password, "")
    }

    func testNameTemplateCountsAcrossSeparateJobs() throws {
        let inputs = try ["Kış.png", "Yaz.png", "Güz.png"].map(image)
        var state = JobQueueState()
        let batch = state.enqueue(inputs, operation: .convert("jpg"), options: options("Out", template: "{n}-{name}"))
        runAll(&state)
        let names = state.jobs(in: batch).flatMap { job -> [String] in
            if case .done(let urls) = job.status { return urls.map(\.lastPathComponent) }
            return []
        }
        XCTAssertEqual(names, ["1-Kış.jpg", "2-Yaz.jpg", "3-Güz.jpg"])
    }
}
