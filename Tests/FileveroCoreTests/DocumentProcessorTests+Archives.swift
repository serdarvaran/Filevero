import CryptoKit
import Foundation
import XCTest

@testable import FileveroCore

extension DocumentEngineTests {
    func testSubtitleRoundTripKeepsTimingUnicodeAndCueText() throws {
        let input = try file(
            "Captions.srt",
            "1\n00:00:01,250 --> 00:00:03,875\n<b>Merhaba Şişli</b>\nSecond line\n\n2\n01:02:03,004 --> 01:02:04,999\nA &amp; B\n"
        )
        let vtt = try convert(input, "vtt")
        XCTAssertTrue(try DocumentText.read(vtt).hasPrefix("WEBVTT\n"))
        let restored = try convert(vtt, "srt")
        let cues = try SubtitleCodec.parse(DocumentText.read(restored))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1250)
        XCTAssertEqual(cues[0].end, 3875)
        XCTAssertEqual(cues[1].start, 3_723_004)
        XCTAssertTrue(cues[0].text.contains("Şişli"))
        XCTAssertNotEqual(restored, input)
        let txt = try convert(vtt, "txt")
        let plain = try DocumentText.read(txt)
        XCTAssertTrue(plain.contains("Merhaba Şişli"))
        XCTAssertTrue(plain.contains("A & B"))
        XCTAssertFalse(plain.contains("<b>"))
    }

    func testWebVTTSkipsNotesAndStylesAndUnderstandsMinuteTimestamps() throws {
        let source = """
            WEBVTT

            NOTE ignored note
            00:00.000 --> 00:01.000

            STYLE
            ::cue { color: white; }

            caption-1
            00:01.250 --> 00:02.500 align:start position:10%
            <v Speaker><c.yellow>Hello</c></v>

            """
        let cues = try SubtitleCodec.parse(source)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1250)
        XCTAssertEqual(cues[0].settings, "align:start position:10%")
        let input = try file("Cue.vtt", source)
        let srt = try DocumentText.read(convert(input, "srt"))
        XCTAssertTrue(srt.contains("Hello"))
        XCTAssertFalse(srt.contains("<v "))
        XCTAssertThrowsError(try SubtitleCodec.parse("1\n00:00:03,000 --> 00:00:01,000\nBad\n"))
        XCTAssertThrowsError(try SubtitleCodec.parse("not subtitles"))
    }

    func testZIPTARGZIPRoundTripsNestedFilesAndUnicodeWithoutOverwritingOriginals() throws {
        let contents = root.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("empty", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try Data("Merhaba Şişli\n".utf8).write(to: contents.appendingPathComponent("nested/şeker.txt"))
        try Data().write(to: contents.appendingPathComponent("empty.txt"))
        try Data([0, 1, 2, 0, 255]).write(to: contents.appendingPathComponent("binary.dat"))
        try FileManager.default.createSymbolicLink(
            atPath: contents.appendingPathComponent("safe-link").path, withDestinationPath: "nested/şeker.txt")
        let fileExtensions = [
            "zip": "zip", "tar": "tar", "gz": "tar.gz", "bz2": "tar.bz2", "xz": "tar.xz", "7z": "7z",
        ]
        for sourceFormat in fileExtensions.keys.sorted() {
            let source = root.appendingPathComponent("Original \(sourceFormat).\(fileExtensions[sourceFormat]!)")
            try ArchiveCodec.create(from: contents, at: source, format: sourceFormat, token: .init())
            let original = try Data(contentsOf: source)
            for target in fileExtensions.keys.sorted() where sourceFormat != target {
                let result = try convert(source, target)
                XCTAssertEqual(result.lastPathComponent, "Original \(sourceFormat).\(fileExtensions[target]!)")
                let folder = try XCTUnwrap(
                    DocumentEngine.extractArchive(result, options: .init(), token: .init()).first)
                XCTAssertTrue(folder.lastPathComponent.hasPrefix("Original \(sourceFormat) Extracted"))
                XCTAssertEqual(
                    try String(contentsOf: folder.appendingPathComponent("nested/şeker.txt"), encoding: .utf8),
                    "Merhaba Şişli\n")
                XCTAssertEqual(
                    try Data(contentsOf: folder.appendingPathComponent("binary.dat")), Data([0, 1, 2, 0, 255]))
                XCTAssertEqual(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: folder.appendingPathComponent("safe-link").path), "nested/şeker.txt")
                var isDirectory: ObjCBool = false
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: folder.appendingPathComponent("empty").path, isDirectory: &isDirectory))
                XCTAssertTrue(isDirectory.boolValue)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testArchiveCompressionProfilesAffectZIPAndGZIPAndRemainExtractable() throws {
        let payload = root.appendingPathComponent("Compression payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let bytes = Data(String(repeating: "Filevero compression fixture 0123456789\n", count: 12000).utf8)
        try bytes.write(to: payload.appendingPathComponent("payload.txt"))
        let source = root.appendingPathComponent("Compression source.tar")
        try ArchiveCodec.create(from: payload, at: source, format: "tar", token: .init())
        for format in ["zip", "gz"] {
            var sizes: [Int] = []
            for preset in ["fast", "balanced", "maximum"] {
                var options = OperationOptions()
                options.compressionPreset = preset
                let output = try XCTUnwrap(
                    DocumentEngine.convert(source, to: format, options: options, token: .init()).first)
                sizes.append(try Data(contentsOf: output).count)
                let extracted = root.appendingPathComponent("\(format) \(preset)", isDirectory: true)
                try ArchiveCodec.extract(output, into: extracted, token: .init())
                XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("payload.txt")), bytes)
            }
            XCTAssertLessThan(sizes[1], sizes[0] / 4, format)
            XCTAssertLessThanOrEqual(sizes[2], sizes[1], format)
        }
        for format in ["bz2", "xz", "7z"] {
            for preset in ["fast", "balanced", "maximum"] {
                var options = OperationOptions()
                options.compressionPreset = preset
                let output = try XCTUnwrap(
                    DocumentEngine.convert(source, to: format, options: options, token: .init()).first)
                if preset != "fast" {
                    XCTAssertLessThan(try Data(contentsOf: output).count, bytes.count / 4, "\(format) \(preset)")
                }
                let extracted = root.appendingPathComponent("\(format) \(preset)", isDirectory: true)
                try ArchiveCodec.extract(output, into: extracted, token: .init())
                XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("payload.txt")), bytes)
            }
        }
    }

    func testArchiveFormatsAreOfferedForExtractionAndConversion() {
        for ext in ["7z", "bz2", "tbz2", "tbz", "xz", "txz", "tgz"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertEqual(FileCategory.detect(url), .archive, ext)
            XCTAssertEqual(FeatureCatalog.tools(for: [url]), [.extractArchive], ext)
        }
        let rar = URL(fileURLWithPath: "/tmp/sample.rar")
        XCTAssertEqual(Set(FeatureCatalog.formats(for: [rar])), ["zip", "tar", "gz", "bz2", "xz", "7z"])
        // Windows has no 7z or xz writer, so those targets stay out of the shared contract.
        XCTAssertEqual(Set(FeatureCatalog.conversionMatrix["rar"] ?? []), ["zip", "tar", "gz", "bz2"])
    }

    func testSingleBZIP2AndXZStreamsExtractToTheirOriginalFile() throws {
        let text = "one compressed stream\n"
        let txt = try file("Single.txt", text)
        let bzip2 = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/bzip2"), ["-c", txt.path])
        // Apple's LZMA encoder writes the xz container.
        let streams = [
            "Single.txt.bz2": bzip2.output,
            "Single.txt.xz": try (Data(text.utf8) as NSData).compressed(using: .lzma) as Data,
        ]
        for (name, data) in streams {
            let source = root.appendingPathComponent(name)
            try data.write(to: source)
            let folder = try XCTUnwrap(DocumentEngine.extractArchive(source, options: .init(), token: .init()).first)
            XCTAssertEqual(try DocumentText.read(folder.appendingPathComponent("Single.txt")), text, name)
        }
    }

    func testStoredRARAndOrdinaryGZIPAreReadable() throws {
        let rar = root.appendingPathComponent("Stored.rar")
        try Self.storedRAR(name: "hello.txt", payload: Data("RAR round trip\n".utf8)).write(to: rar)
        for format in ["zip", "tar", "gz"] {
            let converted = try convert(rar, format)
            let extracted = try XCTUnwrap(
                DocumentEngine.extractArchive(converted, options: .init(), token: .init()).first)
            XCTAssertEqual(try DocumentText.read(extracted.appendingPathComponent("hello.txt")), "RAR round trip\n")
        }
        let txt = try file("Single.txt", "one gzip stream\n")
        let gzip = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-c", txt.path])
        let gz = root.appendingPathComponent("Single.txt.gz")
        try gzip.output.write(to: gz)
        let folder = try XCTUnwrap(DocumentEngine.extractArchive(gz, options: .init(), token: .init()).first)
        XCTAssertEqual(try DocumentText.read(folder.appendingPathComponent("Single.txt")), "one gzip stream\n")
    }

    func testArchiveRejectsTraversalAbsolutePathsEscapingLinksAndInvalidContainers() throws {
        let outside = root.appendingPathComponent("outside.txt")
        for (index, name) in [
            "../outside.txt", "/tmp/filevero-escape.txt", "C:\\outside.txt", "folder/../../outside.txt",
        ].enumerated() {
            let source = root.appendingPathComponent("Traversal \(index).tar")
            try Self.tar(name: name, payload: Data("escape".utf8)).write(to: source)
            XCTAssertThrowsError(try DocumentEngine.extractArchive(source, options: .init(), token: .init()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        }
        let link = root.appendingPathComponent("Escape link.tar")
        try Self.tar(name: "link", payload: Data(), type: 50, link: "../../outside").write(to: link)
        XCTAssertThrowsError(try DocumentEngine.extractArchive(link, options: .init(), token: .init()))
        for ext in ["zip", "rar", "gz", "bz2", "xz", "7z"] {
            let invalid = try file("Invalid.\(ext)", "plain text")
            XCTAssertThrowsError(try DocumentEngine.extractArchive(invalid, options: .init(), token: .init()))
        }
    }

    func testUpstreamRAR4AndCompressedRAR5Interoperability() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Reference/archive-fixtures")
        for name in [
            "test_read_format_rar.rar", "test_read_format_rar5_stored.rar", "test_read_format_rar5_compressed.rar",
        ] {
            let source = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: source)
            for format in ["zip", "tar", "gz"] {
                let archive = try convert(source, format)
                let output = try XCTUnwrap(
                    DocumentEngine.extractArchive(archive, options: .init(), token: .init()).first)
                if name.contains("compressed") {
                    let bytes = try Data(contentsOf: output.appendingPathComponent("test.bin"))
                    XCTAssertEqual(bytes.count, 1200)
                    XCTAssertEqual(
                        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                        "588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375")
                } else if name.contains("rar5") {
                    XCTAssertTrue(
                        try DocumentText.read(output.appendingPathComponent("helloworld.txt")).contains(
                            "hello libarchive"))
                } else {
                    XCTAssertTrue(
                        try DocumentText.read(output.appendingPathComponent("test.txt")).contains("test text document"))
                    XCTAssertEqual(
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: output.appendingPathComponent("testlink").path), "test.txt")
                }
            }
        }
    }

    static func storedRAR(name: String, payload: Data) -> Data {
        func block(_ body: Data) -> Data { little(UInt64(crc32(body) & 0xffff), count: 2) + body }
        var result = Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00])
        result += block(Data([0x73]) + little(0, count: 2) + little(13, count: 2) + Data(repeating: 0, count: 6))
        let filename = Data(name.utf8)
        var header = Data([0x74]) + little(0x8000, count: 2) + little(UInt64(32 + filename.count), count: 2)
        header += little(UInt64(payload.count), count: 4) + little(UInt64(payload.count), count: 4) + Data([3])
        header += little(UInt64(crc32(payload)), count: 4) + little(0, count: 4) + Data([20, 0x30])
        header += little(UInt64(filename.count), count: 2) + little(0x81a4, count: 4) + filename
        result += block(header) + payload
        result += block(Data([0x7b]) + little(0, count: 2) + little(7, count: 2))
        return result
    }

    static func tar(name: String, payload: Data, type: UInt8 = 48, link: String = "") -> Data {
        var header = Data(repeating: 0, count: 512)
        func put(_ value: String, at offset: Int, length: Int) {
            header.replaceSubrange(offset..<(offset + min(length, value.utf8.count)), with: value.utf8.prefix(length))
        }
        put(name, at: 0, length: 100)
        put("0000644\0", at: 100, length: 8)
        put("0000000\0", at: 108, length: 8)
        put("0000000\0", at: 116, length: 8)
        put(String(format: "%011o", payload.count) + "\0", at: 124, length: 12)
        put("00000000000\0", at: 136, length: 12)
        put("        ", at: 148, length: 8)
        header[156] = type
        put(link, at: 157, length: 100)
        put("ustar\0", at: 257, length: 6)
        put("00", at: 263, length: 2)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", at: 148, length: 8)
        return header + payload + Data(repeating: 0, count: (512 - payload.count % 512) % 512 + 1024)
    }
}
