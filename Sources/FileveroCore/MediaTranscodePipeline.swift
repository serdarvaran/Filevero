import Foundation

public struct MediaStream: Sendable, Equatable {
    public let index: Int
    public let kind: String
    public let codec: String
    public let duration: Double?
    public let width: Int?
    public let height: Int?
    public let channels: Int?
    public let sampleRate: Int?
    public let bitsPerSample: Int?
    public let bitsPerRawSample: Int?
    public let sampleFormat: String?
    public let bitRate: Int?
    public let frameRate: Double?
    public let isAttachedPicture: Bool
    public let rotation: Int
    public let metadata: [String: String]

    public init(
        index: Int, kind: String, codec: String, duration: Double?, width: Int?, height: Int?,
        channels: Int?, sampleRate: Int?, bitsPerSample: Int?, bitsPerRawSample: Int?,
        sampleFormat: String?, bitRate: Int?, frameRate: Double?, isAttachedPicture: Bool,
        rotation: Int, metadata: [String: String]
    ) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.duration = duration
        self.width = width
        self.height = height
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.bitsPerRawSample = bitsPerRawSample
        self.sampleFormat = sampleFormat
        self.bitRate = bitRate
        self.frameRate = frameRate
        self.isAttachedPicture = isAttachedPicture
        self.rotation = rotation
        self.metadata = metadata
    }
}

public struct MediaChapter: Sendable, Equatable {
    public let index: Int
    public let start: Double
    public let end: Double
    public let metadata: [String: String]

    public init(index: Int, start: Double, end: Double, metadata: [String: String]) {
        self.index = index
        self.start = start
        self.end = end
        self.metadata = metadata
    }
}

public struct MediaInfo: Sendable, Equatable {
    public let duration: Double
    public let size: Int64
    public let format: String
    public let streams: [MediaStream]
    public let chapters: [MediaChapter]
    public let metadata: [String: String]

    public var video: MediaStream? {
        streams.first { $0.kind == "video" && !$0.isAttachedPicture && ($0.width ?? 0) > 0 }
    }
    public var audio: MediaStream? { streams.first { $0.kind == "audio" } }
    public var hasVideo: Bool { video != nil }
    public var hasAudio: Bool { audio != nil }

    public init(
        duration: Double, size: Int64, format: String, streams: [MediaStream],
        chapters: [MediaChapter], metadata: [String: String]
    ) {
        self.duration = duration
        self.size = size
        self.format = format
        self.streams = streams
        self.chapters = chapters
        self.metadata = metadata
    }
}

public struct AudioLoudness: Sendable, Equatable {
    public let integrated: Double
    public let truePeak: Double
    public let range: Double
    public let threshold: Double
    public let targetOffset: Double

    public init(integrated: Double, truePeak: Double, range: Double, threshold: Double, targetOffset: Double) {
        self.integrated = integrated
        self.truePeak = truePeak
        self.range = range
        self.threshold = threshold
        self.targetOffset = targetOffset
    }
}

/// Comprehensive media transcoding, analysis, filtering, and remuxing engine using FFmpeg/FFprobe.
public enum MediaTranscodePipeline {
    public static let audioFormats: Set<String> = [
        "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "aac",
    ]
    public static let videoFormats: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "gif"]

    public static func inspect(_ input: URL, token: CancellationToken = .init()) throws -> MediaInfo {
        try validateInput(input, token: token)
        let result = try ExecutionPipeline.run(
            Dependencies.executable("ffprobe"), probeArguments(input), token: token)
        return try mediaInfo(probe: result.output, input: input)
    }

    /// Suspends while ffprobe runs instead of blocking a thread.
    public static func inspectAsync(_ input: URL, token: CancellationToken = .init()) async throws -> MediaInfo {
        try validateInput(input, token: token)
        let result = try await ExecutionPipeline.runAsync(
            Dependencies.executable("ffprobe"), probeArguments(input), token: token)
        return try mediaInfo(probe: result.output, input: input)
    }

    private static func probeArguments(_ input: URL) -> [String] {
        ["-v", "error", "-show_format", "-show_streams", "-show_chapters", "-of", "json", input.path]
    }

    private static func mediaInfo(probe output: Data, input: URL) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw FileveroError.failed("Could not inspect media information.")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = (root["streams"] as? [[String: Any]] ?? []).map { item in
            let metadata = tags(item["tags"])
            let sideData = item["side_data_list"] as? [[String: Any]] ?? []
            let disposition = item["disposition"] as? [String: Any] ?? [:]
            let rotation = sideData.compactMap { integer($0["rotation"]) }.first ?? Int(metadata["rotate"] ?? "0") ?? 0
            let swap = abs(rotation % 180) == 90
            let width = integer(item[swap ? "height" : "width"])
            let height = integer(item[swap ? "width" : "height"])
            return MediaStream(
                index: integer(item["index"]) ?? 0, kind: item["codec_type"] as? String ?? "unknown",
                codec: item["codec_name"] as? String ?? "unknown", duration: number(item["duration"]), width: width,
                height: height, channels: integer(item["channels"]), sampleRate: integer(item["sample_rate"]),
                bitsPerSample: integer(item["bits_per_sample"]), bitsPerRawSample: integer(item["bits_per_raw_sample"]),
                sampleFormat: item["sample_fmt"] as? String, bitRate: integer(item["bit_rate"]),
                frameRate: fraction(item["avg_frame_rate"] as? String) ?? fraction(item["r_frame_rate"] as? String),
                isAttachedPicture: integer(disposition["attached_pic"]) == 1, rotation: rotation, metadata: metadata)
        }
        let chapters = (root["chapters"] as? [[String: Any]] ?? []).enumerated().map { index, item in
            MediaChapter(
                index: index, start: number(item["start_time"]) ?? 0, end: number(item["end_time"]) ?? 0,
                metadata: tags(item["tags"]))
        }
        let duration = number(format["duration"]) ?? streams.compactMap(\.duration).max() ?? 0
        let size = (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MediaInfo(
            duration: duration, size: size, format: format["format_name"] as? String ?? input.pathExtension,
            streams: streams, chapters: chapters, metadata: tags(format["tags"]))
    }

    public static func readMetadata(_ input: URL, token: CancellationToken = .init()) throws -> [String: String] {
        metadataFields(try inspect(input, token: token))
    }

    public static func readMetadataAsync(
        _ input: URL, token: CancellationToken = .init()
    ) async throws -> [String: String] {
        metadataFields(try await inspectAsync(input, token: token))
    }

    private static func metadataFields(_ info: MediaInfo) -> [String: String] {
        var fields = Dictionary(uniqueKeysWithValues: info.metadata.map { ("file:\($0.key)", $0.value) })
        for stream in info.streams {
            for (key, value) in stream.metadata { fields["track[\(stream.index)]:\(key)"] = value }
        }
        for chapter in info.chapters {
            for (key, value) in chapter.metadata { fields["chapter[\(chapter.index)]:\(key)"] = value }
        }
        return fields
    }

    public static func editMetadata(
        _ input: URL, metadata: [String: String], removeAll: Bool = false, options: OperationOptions = .init(),
        token: CancellationToken = .init(), progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        let info = try inspect(input, token: token)
        let ext = input.pathExtension.lowercased()
        guard audioFormats.contains(ext) || videoFormats.contains(ext) else {
            throw FileveroError.unsupported("This is not a supported audio or video file.")
        }
        let output = try outputURL(input, ext: ext, suffix: " Metadata", options: options)
        var arguments = ["-i", input.path, "-map", "0", "-c", "copy"]
        if removeAll {
            arguments += [
                "-map", "-0:d?", "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1", "-fflags",
                "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
            ]
            for stream in info.streams where stream.isAttachedPicture {
                arguments += ["-map", "-0:\(stream.index)"]
            }
        }
        for key in metadata.keys.sorted() {
            guard let value = metadata[key], !key.isEmpty, !key.contains("\0"), !value.contains("\0") else {
                throw FileveroError.invalidInput("Metadata fields cannot be empty or contain null characters.")
            }
            let (specifier, field) = try metadataSpecifier(key)
            guard !field.isEmpty, !field.contains("=") else {
                throw FileveroError.invalidInput("Invalid metadata field: \(key)")
            }
            arguments += [specifier, "\(field)=\(value)"]
        }
        if ["mp4", "mov", "m4a", "m4v"].contains(ext) { arguments += ["-movflags", "+use_metadata_tags"] }
        try render(arguments, to: output, token: token, duration: info.duration, progress: progress)
        return [output]
    }

    public static func convert(
        _ input: URL, to format: String, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        let info = try inspect(input, token: token)
        let ext = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard audioFormats.contains(ext) || videoFormats.contains(ext) else {
            throw FileveroError.unsupported("Unsupported media format: \(format)")
        }
        try validateQuality(options.quality)
        try validateMediaPreferences(options)
        let output = try outputURL(input, ext: ext, options: options)
        var arguments = ["-i", input.path]
        if audioFormats.contains(ext) {
            try requireAudio(info)
            arguments +=
                ["-map", "0:a:0", "-vn"]
                + audioEncoding(
                    ext, quality: options.quality, bitrate: options.audioBitrate * 1000, source: info.audio,
                    pcmCodec: try pcmCodec(for: ext, source: info.audio, setting: options.audioSampleDepth),
                    compressionPreset: options.compressionPreset)
        } else {
            try requireVideo(info)
            let videoMap = try videoStream(info)
            arguments += ["-map", videoMap]
            if ext == "gif" {
                let scale = try scalingFilter(options)
                let first =
                    (["fps=\(options.gifFrameRate)"] + (scale.map { [$0] } ?? []) + [
                        "scale=w='min(\(options.gifMaxWidth),iw)':h=-2:force_original_aspect_ratio=decrease"
                    ]).joined(separator: ",")
                arguments += [
                    "-filter_complex",
                    "[\(videoMap)]\(first),split[p0][p1];[p0]palettegen=stats_mode=diff[pal];[p1][pal]paletteuse=dither=sierra2_4a",
                    "-an", "-loop", "0",
                ]
                arguments.removeSubrange(2..<4)
            } else {
                arguments += ["-map", "0:a:0?"]
                if let scale = try scalingFilter(options) { arguments += ["-vf", scale] }
                if options.videoEncoder == "hardware" {
                    guard ["mp4", "mov", "mkv"].contains(ext) else {
                        throw FileveroError.unsupported("Hardware encoding is not available for this output format.")
                    }
                    let bitrate = options.videoBitrateKbps ?? 6000
                    guard (500...100000).contains(bitrate) else {
                        throw FileveroError.invalidInput("Video bitrate must be between 500 and 100000 kbps.")
                    }
                    let available = try ExecutionPipeline.run(
                        Dependencies.executable("ffmpeg"), ["-hide_banner", "-encoders"], token: token)
                    guard available.text.contains("h264_videotoolbox") else {
                        throw FileveroError.missingDependency("h264_videotoolbox")
                    }
                    arguments +=
                        ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k", "-pix_fmt", "yuv420p"]
                        + audioEncoding(
                            "m4a", quality: options.quality, bitrate: options.audioBitrate * 1000, source: info.audio)
                    if ["mp4", "mov"].contains(ext) { arguments += ["-movflags", "+faststart"] }
                } else if options.videoEncoder == nil || options.videoEncoder == "software" {
                    arguments += videoEncoding(
                        ext, quality: options.quality, audioBitrate: options.audioBitrate * 1000,
                        sourceAudio: info.audio)
                } else {
                    throw FileveroError.invalidInput("Unknown video encoder preference.")
                }
            }
        }
        if options.preserveMetadata {
            arguments += ["-map_metadata", "0"]
        } else {
            arguments += ["-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1"]
        }
        arguments += metadataArguments(options.metadata)
        try render(arguments, to: output, token: token, duration: info.duration, progress: progress)
        return [output]
    }

    public static func tool(
        _ kind: ToolKind, inputs: [URL], options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard !inputs.isEmpty else { throw FileveroError.invalidInput("Choose at least one media file.") }
        try token.check()
        try validateQuality(options.quality)
        try validateMediaPreferences(options)
        if kind == .joinVideos { return try join(inputs, options: options, token: token, progress: progress) }
        if kind == .joinAudio { return try joinAudio(inputs, options: options, token: token, progress: progress) }
        var results: [URL] = []
        do {
            for (index, input) in inputs.enumerated() {
                let itemProgress: ProgressHandler = { value, label in
                    progress(
                        OperationProgress.map(
                            value, from: Double(index) / Double(inputs.count),
                            to: Double(index + 1) / Double(inputs.count)), label)
                }
                itemProgress(OperationProgress.indeterminate, "Inspecting \(input.lastPathComponent)…")
                try token.check()
                let info = try inspect(input, token: token)
                switch kind {
                case .compress:
                    results += try compress(input, info: info, options: options, token: token, progress: itemProgress)
                case .removeMetadata:
                    results += try editMetadata(
                        input, metadata: options.metadata,
                        removeAll: options.metadataRemoveAll || options.metadata.isEmpty, options: options,
                        token: token, progress: itemProgress)
                case .normalizeAudio:
                    results += try normalize(input, info: info, options: options, token: token, progress: itemProgress)
                case .muteVideo:
                    try requireVideo(info)
                    let out = try outputURL(input, ext: videoExtension(input), suffix: " Muted", options: options)
                    try render(
                        ["-i", input.path, "-map", try videoStream(info), "-c:v", "copy", "-an"], to: out, token: token,
                        duration: info.duration, progress: itemProgress)
                    results.append(out)
                case .trimVideo, .trimAudio:
                    results += try trim(
                        input, info: info, audio: kind == .trimAudio, options: options, token: token,
                        progress: itemProgress)
                case .cropVideo:
                    results += try crop(input, info: info, options: options, token: token, progress: itemProgress)
                case .changeVideoSpeed:
                    results += try changeSpeed(
                        input, info: info, options: options, token: token, progress: itemProgress)
                case .videoSnapshots:
                    results += try snapshots(input, info: info, options: options, token: token, progress: itemProgress)
                case .splitVideo:
                    results += try split(input, info: info, options: options, token: token, progress: itemProgress)
                case .audioToVideo:
                    results += try visualization(
                        input, info: info, options: options, token: token, progress: itemProgress)
                case .audioChannels:
                    results += try channels(input, info: info, options: options, token: token, progress: itemProgress)
                case .redactVideo:
                    results += try redactVideo(
                        input, info: info, options: options, token: token, progress: itemProgress)
                case .redactAudio:
                    results += try redactAudio(
                        input, info: info, options: options, token: token, progress: itemProgress)
                default: throw FileveroError.unsupported("\(kind.title) does not operate on audio or video files.")
                }
            }
            try OutputFiles.validate(results)
            return results
        } catch {
            for output in results { try? FileManager.default.removeItem(at: output) }
            if kind == .splitVideo && !options.joinSplitClips {
                for folder in Set(results.map { $0.deletingLastPathComponent() }) {
                    if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            }
            throw error
        }
    }

    public static func measureLoudness(
        _ input: URL, target: Double = -16, range: Double = 11, peak: Double = -1.5, token: CancellationToken = .init(),
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> AudioLoudness {
        try validateNormalization(target: target, range: range, peak: peak)
        let result = try ffmpeg(
            [
                "-i", input.path, "-map", "0:a:0", "-af",
                "loudnorm=I=\(decimal(target)):LRA=\(decimal(range)):TP=\(decimal(peak)):print_format=json", "-f",
                "null", "-",
            ], token: token, verbosity: "info", duration: try inspect(input, token: token).duration,
            progress: { value, _ in progress(value, "Measuring audio loudness…") })
        let text = String(decoding: result.errorOutput, as: UTF8.self)
        guard let opening = text.range(of: "{", options: .backwards),
            let closing = text.range(of: "}", options: .backwards), opening.lowerBound < closing.upperBound,
            let data = String(text[opening.lowerBound..<closing.upperBound]).data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FileveroError.failed("Could not measure the audio loudness.") }
        return AudioLoudness(
            integrated: number(json["input_i"]) ?? -.infinity, truePeak: number(json["input_tp"]) ?? -.infinity,
            range: number(json["input_lra"]) ?? 0, threshold: number(json["input_thresh"]) ?? -70,
            targetOffset: number(json["target_offset"]) ?? 0)
    }

    public static func previewChannel(
        _ input: URL, channel: Int, options: OperationOptions = .init(), token: CancellationToken = .init()
    ) throws -> URL {
        try validateChannel(channel)
        let job = try channelPreviewJob(input, info: try inspect(input, token: token), channel: channel, options: options)
        do {
            try render(job.arguments, to: job.output, token: token)
            return job.output
        } catch {
            try? FileManager.default.removeItem(at: job.output.deletingLastPathComponent())
            throw error
        }
    }

    /// Suspends while ffprobe and ffmpeg run instead of blocking a thread.
    public static func previewChannelAsync(
        _ input: URL, channel: Int, options: OperationOptions = .init(), token: CancellationToken = .init()
    ) async throws -> URL {
        try validateChannel(channel)
        let info = try await inspectAsync(input, token: token)
        let job = try channelPreviewJob(input, info: info, channel: channel, options: options)
        do {
            try await renderAsync(job.arguments, to: job.output, token: token)
            return job.output
        } catch {
            try? FileManager.default.removeItem(at: job.output.deletingLastPathComponent())
            throw error
        }
    }

    private static func validateChannel(_ channel: Int) throws {
        guard channel == 0 || channel == 1 else {
            throw FileveroError.invalidInput("Choose the left or right channel.")
        }
    }

    /// Creates the preview's private temporary folder; the caller removes it if rendering fails.
    private static func channelPreviewJob(
        _ input: URL, info: MediaInfo, channel: Int, options: OperationOptions
    ) throws -> (arguments: [String], output: URL) {
        try requireAudio(info)
        let filter =
            try channelFilter(info: info, options: options) + ",pan=mono|c0=c\(options.channels == 1 ? 0 : channel)"
        let directory = try OutputFiles.temporaryDirectory()
        let out = directory.appendingPathComponent(channel == 0 ? "Left.wav" : "Right.wav")
        return (["-i", input.path, "-map", "0:a:0", "-af", filter, "-c:a", "pcm_s16le"], out)
    }

    /// Runs the synchronous tool pipeline on a dispatch thread so no cooperative-pool thread waits on its
    /// ffmpeg steps. A full async rewrite of every tool would duplicate the whole pipeline.
    public static func toolAsync(
        _ kind: ToolKind, inputs: [URL], options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) async throws -> [URL] {
        try await ExecutionPipeline.offload {
            try tool(kind, inputs: inputs, options: options, token: token, progress: progress)
        }
    }

    @discardableResult static func ffmpeg(
        _ arguments: [String], token: CancellationToken, verbosity: String = "error", overwrite: Bool = false,
        duration: Double? = nil, progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> ProcessExecutionResult {
        let parser = FFmpegProgressParser(duration: duration, progress: progress)
        return try ExecutionPipeline.run(
            Dependencies.executable("ffmpeg"), ffmpegArguments(arguments, verbosity: verbosity, overwrite: overwrite),
            token: token, onOutput: { parser.append($0) })
    }

    @discardableResult static func ffmpegAsync(
        _ arguments: [String], token: CancellationToken, verbosity: String = "error", overwrite: Bool = false,
        duration: Double? = nil, progress: @escaping ProgressHandler = { _, _ in }
    ) async throws -> ProcessExecutionResult {
        let parser = FFmpegProgressParser(duration: duration, progress: progress)
        return try await ExecutionPipeline.runAsync(
            Dependencies.executable("ffmpeg"), ffmpegArguments(arguments, verbosity: verbosity, overwrite: overwrite),
            token: token, onOutput: { parser.append($0) })
    }

    private static func ffmpegArguments(_ arguments: [String], verbosity: String, overwrite: Bool) -> [String] {
        [
            "-hide_banner", "-nostdin", "-v", verbosity, overwrite ? "-y" : "-n", "-nostats", "-stats_period",
            "0.2", "-progress", "pipe:1",
        ] + arguments
    }
}

// MARK: - Compatibility Bridge
public typealias MediaEngine = MediaTranscodePipeline

