import XCTest

@testable import FileveroCore

final class MediaAsyncPipelineTests: XCTestCase {
    private var directory: URL!
    private var audio: URL!

    override func setUpWithError() throws {
        directory = try OutputFiles.temporaryDirectory()
        audio = directory.appendingPathComponent("Stereo.wav")
        try ProcessRunner.run(
            Dependencies.executable("ffmpeg"),
            [
                "-v", "error", "-nostdin", "-f", "lavfi", "-i",
                "aevalsrc=exprs='0.2*sin(2*PI*440*t)|0.8*sin(2*PI*880*t)':s=48000:d=1", "-metadata", "title=Async title",
                audio.path,
            ])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAsyncInspectAndMetadataMatchTheSyncAPIs() async throws {
        let sync = try MediaEngine.inspect(audio)
        let async = try await MediaEngine.inspectAsync(audio)
        XCTAssertEqual(async.duration, sync.duration)
        XCTAssertEqual(async.audio?.channels, 2)
        XCTAssertEqual(async.streams.count, sync.streams.count)
        let metadata = try await MediaEngine.readMetadataAsync(audio)
        XCTAssertEqual(metadata, try MediaEngine.readMetadata(audio))
        XCTAssertEqual(metadata["file:title"], "Async title")
    }

    func testAsyncWaveformMatchesTheSyncAPI() async throws {
        for channel in [nil, 0, 1] as [Int?] {
            let async = try await MediaPreviewEngine.waveformPeaksAsync(audio, bins: 50, channel: channel)
            XCTAssertEqual(async, try MediaPreviewEngine.waveformPeaks(audio, bins: 50, channel: channel))
        }
        do {
            _ = try await MediaPreviewEngine.waveformPeaksAsync(audio, channel: 2)
            XCTFail("Expected an invalid channel error")
        } catch FileveroError.invalidInput {}
    }

    func testAsyncChannelPreviewRendersOneMonoChannel() async throws {
        let left = try await MediaEngine.previewChannelAsync(audio, channel: 0)
        defer { try? FileManager.default.removeItem(at: left.deletingLastPathComponent()) }
        XCTAssertEqual(left.lastPathComponent, "Left.wav")
        XCTAssertEqual(try MediaEngine.inspect(left).audio?.channels, 1)
        let peaks = try MediaPreviewEngine.waveformPeaks(left, bins: 20)
        XCTAssertEqual(peaks.max() ?? 0, 0.2, accuracy: 0.01)
    }

    func testAsyncToolProducesTheSameOutputAsTheSyncTool() async throws {
        var options = OperationOptions()
        options.outputDirectory = directory
        options.channels = 1
        let outputs = try await MediaEngine.toolAsync(.audioChannels, inputs: [audio], options: options, token: .init())
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try MediaEngine.inspect(XCTUnwrap(outputs.first)).audio?.channels, 1)
    }

    func testCancelledTokenStopsAsyncMediaCalls() async {
        let token = CancellationToken()
        token.cancel()
        do {
            _ = try await MediaEngine.inspectAsync(audio, token: token)
            XCTFail("Expected cancellation")
        } catch FileveroError.cancelled {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        do {
            _ = try await MediaEngine.previewChannelAsync(audio, channel: 1, token: token)
            XCTFail("Expected cancellation")
        } catch FileveroError.cancelled {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOffloadReturnsResultAndPropagatesErrors() async throws {
        let value = try await ExecutionPipeline.offload { Thread.isMainThread ? -1 : 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await ExecutionPipeline.offload { () -> Int in throw FileveroError.invalidInput("no") }
            XCTFail("Expected the work's error")
        } catch FileveroError.invalidInput(let message) {
            XCTAssertEqual(message, "no")
        }
    }
}
