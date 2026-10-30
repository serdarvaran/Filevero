import CoreGraphics
import XCTest

@testable import FileveroCore

final class MediaCoverArtAndSpeedRegressionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func runFFmpeg(_ arguments: [String]) throws {
        try ProcessRunner.run(
            Dependencies.executable("ffmpeg"), ["-hide_banner", "-nostdin", "-v", "error", "-n"] + arguments)
    }

    private func mp3WithCover() throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let cover = directory.appendingPathComponent("cover.jpg")
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: cover)
        let output = directory.appendingPathComponent("Song.mp3")
        try runFFmpeg([
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2", "-i", cover.path,
            "-map", "0:a:0", "-map", "1:v:0", "-c:a", "libmp3lame", "-c:v", "copy", "-id3v2_version", "3",
            "-disposition:v:0", "attached_pic", output.path,
        ])
        return output
    }

    func testEmbeddedCoverArtIsNotTreatedAsVideo() throws {
        let song = try mp3WithCover()
        let info = try MediaEngine.inspect(song)
        XCTAssertTrue(info.streams.contains { $0.kind == "video" && $0.isAttachedPicture }, "fixture needs cover art")
        XCTAssertTrue(info.hasAudio)
        XCTAssertFalse(info.hasVideo)
        XCTAssertNil(info.video)
        var options = OperationOptions()
        options.speed = 2
        XCTAssertThrowsError(
            try MediaEngine.tool(.changeVideoSpeed, inputs: [song], options: options, token: .init()))
    }

    func testSpeedingUpKeepsTheSourceFrameRate() throws {
        let source = directory.appendingPathComponent("Clip.mp4")
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=4", "-c:v", "libx264", "-preset",
            "ultrafast", "-pix_fmt", "yuv420p", source.path,
        ])
        var options = OperationOptions()
        options.speed = 10
        let output = try XCTUnwrap(
            MediaEngine.tool(.changeVideoSpeed, inputs: [source], options: options, token: .init()).first)
        let info = try MediaEngine.inspect(output)
        XCTAssertEqual(info.duration, 0.4, accuracy: 0.15)
        let frameRate = try XCTUnwrap(info.video?.frameRate)
        XCTAssertLessThanOrEqual(frameRate, 24.01)
        XCTAssertGreaterThan(frameRate, 0)
    }
}
