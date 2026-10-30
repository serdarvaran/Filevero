import CoreGraphics
import XCTest

@testable import FileveroCore

final class MediaOddSizeAndStreamSelectionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func runFFmpeg(_ arguments: [String]) throws {
        try ProcessRunner.run(
            Dependencies.executable("ffmpeg"), ["-hide_banner", "-nostdin", "-v", "error", "-n"] + arguments)
    }

    private func oddSizedVideo() throws -> URL {
        let source = directory.appendingPathComponent("Odd.mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=10:duration=2", "-vf", "format=yuv444p,crop=65:41:0:0",
            "-c:v", "ffv1", source.path,
        ])
        let video = try XCTUnwrap(MediaEngine.inspect(source).video)
        XCTAssertEqual(video.width, 65, "fixture must keep an odd width")
        XCTAssertEqual(video.height, 41, "fixture must keep an odd height")
        return source
    }

    func testEveryVideoEncodeAcceptsOddFrameSizes() throws {
        let source = try oddSizedVideo()
        var options = OperationOptions()
        options.outputDirectory = directory
        options.start = 0.2
        options.end = 1.2
        options.speed = 2
        options.redactions = [.init(x: 5, y: 5, width: 21, height: 13)]
        let tools: [ToolKind] = [.trimVideo, .changeVideoSpeed, .redactVideo, .cropVideo, .splitVideo]
        for tool in tools {
            var toolOptions = options
            if tool == .splitVideo { toolOptions.splitPoints = [1] }
            let outputs = try MediaEngine.tool(tool, inputs: [source], options: toolOptions, token: .init())
            for output in outputs {
                let video = try XCTUnwrap(MediaEngine.inspect(output).video, "\(tool) lost the video")
                XCTAssertEqual(video.width, 66, "\(tool)")
                XCTAssertEqual(video.height, 42, "\(tool)")
            }
        }
        let converted = try XCTUnwrap(MediaEngine.convert(source, to: "mp4", options: options, token: .init()).first)
        XCTAssertEqual(try MediaEngine.inspect(converted).video?.width, 66)
    }

    /// Writes an MP4 whose cover picture (attached_pic) is stream 0 and the real video stream 1.
    private func videoWithLeadingCover() throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let cover = directory.appendingPathComponent("cover.png")
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: cover)
        let written = directory.appendingPathComponent("written.mp4")
        try runFFmpeg([
            "-i", cover.path, "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=10:duration=2", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=2", "-map", "0:v", "-map", "1:v", "-map", "2:a",
            "-c:v:0", "mjpeg", "-c:v:1", "libx264", "-pix_fmt:v:1", "yuv420p", "-c:a", "aac",
            "-disposition:v:0", "attached_pic", "-disposition:v:1", "0", written.path,
        ])
        // ffmpeg writes the cover in moov/udta after the tracks; moving udta first makes the cover stream 0,
        // as files tagged by other software can be. mdat precedes moov, so no chunk offset changes.
        var data = try Data(contentsOf: written)
        let moov = try XCTUnwrap(boxes(in: data, from: 0, to: data.count).first { $0.type == "moov" })
        let children = boxes(in: data, from: moov.start + 8, to: moov.end)
        let reordered = children.sorted { rank($0.type) < rank($1.type) }
        data.replaceSubrange(moov.start + 8..<moov.end, with: reordered.flatMap { data[$0.start..<$0.end] })
        let output = directory.appendingPathComponent("Covered.mp4")
        try data.write(to: output)
        return output
    }

    private func rank(_ type: String) -> Int { type == "mvhd" ? 0 : type == "udta" ? 1 : 2 }

    private func boxes(in data: Data, from start: Int, to end: Int) -> [(type: String, start: Int, end: Int)] {
        var result: [(type: String, start: Int, end: Int)] = []
        var offset = start
        while offset + 8 <= end {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            guard size >= 8, offset + size <= end else { break }
            result.append((type, offset, offset + size))
            offset += size
        }
        return result
    }

    func testVideoToolsUseTheRealVideoStreamWhenCoverArtComesFirst() throws {
        let source = try videoWithLeadingCover()
        let info = try MediaEngine.inspect(source)
        let first = try XCTUnwrap(info.streams.first)
        XCTAssertTrue(first.kind == "video" && first.isAttachedPicture, "fixture needs the cover as stream 0")
        XCTAssertEqual(info.video?.width, 64)
        var options = OperationOptions()
        options.outputDirectory = directory
        options.start = 0
        options.end = 1.5
        options.speed = 2
        options.redactions = [.init(x: 4, y: 4, width: 10, height: 10)]
        options.snapshotTimes = [1]
        let tools: [ToolKind] = [.trimVideo, .changeVideoSpeed, .redactVideo, .cropVideo, .muteVideo, .compress]
        for tool in tools {
            let output = try XCTUnwrap(
                MediaEngine.tool(tool, inputs: [source], options: options, token: .init()).first)
            let video = try XCTUnwrap(MediaEngine.inspect(output).video, "\(tool) lost the video")
            XCTAssertEqual(video.width, 64, "\(tool) encoded the cover picture")
            XCTAssertEqual(video.height, 48, "\(tool) encoded the cover picture")
        }
        let frame = try XCTUnwrap(
            MediaEngine.tool(.videoSnapshots, inputs: [source], options: options, token: .init()).first)
        XCTAssertEqual(try ImageEngine.load(frame).width, 64)
        let converted = try XCTUnwrap(MediaEngine.convert(source, to: "mkv", options: options, token: .init()).first)
        XCTAssertEqual(try MediaEngine.inspect(converted).video?.width, 64)
        let joined = try XCTUnwrap(
            MediaEngine.tool(.joinVideos, inputs: [source, source], options: options, token: .init()).first)
        let joinedInfo = try MediaEngine.inspect(joined)
        XCTAssertEqual(joinedInfo.duration, 4, accuracy: 0.5, "join must use the full-length real video")
    }
}
