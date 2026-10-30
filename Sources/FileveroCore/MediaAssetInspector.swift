import AVFoundation
import Foundation

public struct MediaPreviewResult: Sendable, Equatable {
    public let originalURL: URL
    public let playbackURL: URL
    public let ownedTemporaryDirectory: URL?
    public var isProxy: Bool { playbackURL != originalURL }

    public init(originalURL: URL, playbackURL: URL, ownedTemporaryDirectory: URL?) {
        self.originalURL = originalURL
        self.playbackURL = playbackURL
        self.ownedTemporaryDirectory = ownedTemporaryDirectory
    }

    public func removeTemporaryFiles() {
        if let ownedTemporaryDirectory { try? FileManager.default.removeItem(at: ownedTemporaryDirectory) }
    }
}

/// Dynamic playback previews and streaming waveform analysis for native macOS media views.
public enum MediaAssetInspector {
    public static func prepare(_ input: URL, forceProxy: Bool = false, token: CancellationToken = .init()) async throws
        -> MediaPreviewResult
    {
        try checkCancellation(token)
        guard input.isFileURL, FileManager.default.isReadableFile(atPath: input.path) else {
            throw FileveroError.invalidInput("Choose a readable local media file.")
        }
        if !forceProxy, try await nativelyPlayable(input, token: token) {
            return MediaPreviewResult(originalURL: input, playbackURL: input, ownedTemporaryDirectory: nil)
        }
        let info = try await MediaTranscodePipeline.inspectAsync(input, token: token)
        guard info.hasVideo || info.hasAudio else {
            throw FileveroError.invalidInput("The file has no playable audio or video track.")
        }
        let directory = try OutputFiles.temporaryDirectory()
        do {
            let output = directory.appendingPathComponent(info.hasVideo ? "Preview.mp4" : "Preview.m4a")
            var arguments = [
                "-hide_banner", "-nostdin", "-v", "error", "-n", "-i", input.path, "-map_metadata", "-1",
                "-map_chapters", "-1",
            ]
            if info.hasVideo {
                let scale =
                    "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1"
                arguments += [
                    "-map", try MediaTranscodePipeline.videoStream(info), "-map", "0:a:0?", "-vf", scale, "-c:v",
                    "libx264", "-preset", "veryfast", "-crf", "24", "-pix_fmt", "yuv420p",
                ]
            } else {
                arguments += ["-map", "0:a:0", "-vn"]
            }
            if info.hasAudio { arguments += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"] }
            arguments += ["-movflags", "+faststart", output.path]
            try await ExecutionPipeline.runAsync(Dependencies.executable("ffmpeg"), arguments, token: token)
            try checkCancellation(token)
            try OutputFiles.validate([output])
            guard try await nativelyPlayable(output, token: token) else {
                throw FileveroError.failed("macOS could not open the generated media preview.")
            }
            return MediaPreviewResult(originalURL: input, playbackURL: output, ownedTemporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func waveformPeaks(
        _ input: URL, bins: Int = 600, channel: Int? = nil, token: CancellationToken = .init()
    ) throws -> [Float] {
        try checkCancellation(token)
        try validateBins(bins)
        let info = try MediaTranscodePipeline.inspect(input, token: token)
        let result = try ExecutionPipeline.run(
            Dependencies.executable("ffmpeg"), try waveformArguments(input, info: info, bins: bins, channel: channel),
            token: token)
        try checkCancellation(token)
        return try peaks(from: result, bins: bins)
    }

    /// Suspends while ffprobe and ffmpeg run instead of blocking a thread.
    public static func waveformPeaksAsync(
        _ input: URL, bins: Int = 600, channel: Int? = nil, token: CancellationToken = .init()
    ) async throws -> [Float] {
        try checkCancellation(token)
        try validateBins(bins)
        let info = try await MediaTranscodePipeline.inspectAsync(input, token: token)
        let result = try await ExecutionPipeline.runAsync(
            Dependencies.executable("ffmpeg"), try waveformArguments(input, info: info, bins: bins, channel: channel),
            token: token)
        try checkCancellation(token)
        return try peaks(from: result, bins: bins)
    }

    private static func validateBins(_ bins: Int) throws {
        guard (1...10000).contains(bins) else {
            throw FileveroError.invalidInput("Choose between 1 and 10,000 waveform bins.")
        }
    }

    private static func waveformArguments(
        _ input: URL, info: MediaInfo, bins: Int, channel: Int?
    ) throws -> [String] {
        guard let audio = info.audio else { throw FileveroError.invalidInput("The file has no audio track.") }
        if let channel, channel < 0 || channel >= (audio.channels ?? 1) {
            throw FileveroError.invalidInput("The selected audio channel does not exist.")
        }
        let sampleRate = audio.sampleRate ?? 48000
        let estimated = ceil(info.duration * Double(sampleRate))
        guard sampleRate > 0, estimated.isFinite, estimated > 0, estimated < Double(Int64.max / 4) else {
            throw FileveroError.invalidInput("A waveform requires a finite media duration.")
        }
        let samples = Int64(estimated)
        let desiredBlock = max(1, Int64(ceil(Double(samples) / Double(bins))))
        let frameSize = min(1024, desiredBlock)
        let frameCount = (samples + frameSize - 1) / frameSize
        let framesPerBin = max(1, (frameCount + Int64(bins) - 1) / Int64(bins))
        guard framesPerBin <= Int64(Int32.max) else {
            throw FileveroError.invalidInput("The media is too long for the requested waveform resolution.")
        }
        let groups = (frameCount + framesPerBin - 1) / framesPerBin
        let paddedSamples = groups * framesPerBin * frameSize
        let isolate = channel.map { "pan=mono|c0=c\($0)," } ?? ""
        let filter =
            isolate
            + "apad=whole_len=\(paddedSamples),asetnsamples=n=\(frameSize):p=1,astats=metadata=1:reset=\(framesPerBin):measure_perchannel=none:measure_overall=Peak_level,aselect='lt(selected_n,\(bins))*not(mod(n+1,\(framesPerBin)))',ametadata=print:key=lavfi.astats.Overall.Peak_level:file=-"
        return [
            "-hide_banner", "-nostdin", "-v", "error", "-i", input.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-af", filter, "-f", "null", "-",
        ]
    }

    private static func peaks(from result: ProcessExecutionResult, bins: Int) throws -> [Float] {
        let key = "lavfi.astats.Overall.Peak_level="
        let peaks: [Float] = result.text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(key), let decibels = Double(line.dropFirst(key.count)) else { return nil }
            return decibels.isFinite ? Float(min(1, max(0, pow(10, decibels / 20)))) : 0
        }
        guard !peaks.isEmpty else { throw FileveroError.failed("Could not decode the audio waveform.") }
        if peaks.count == bins { return peaks }
        return (0..<bins).map { index in
            let lower = min(peaks.count - 1, index * peaks.count / bins)
            let upper = min(peaks.count, max(lower + 1, (index + 1) * peaks.count / bins))
            return peaks[lower..<upper].max() ?? 0
        }
    }

    public static func processedPreview(
        _ kind: ToolKind, input: URL, options: OperationOptions = .init(), token: CancellationToken = .init()
    ) async throws -> MediaPreviewResult {
        let supported: Set<ToolKind> = [
            .normalizeAudio, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .splitVideo, .audioToVideo,
            .trimAudio, .audioChannels, .redactVideo, .redactAudio,
        ]
        guard supported.contains(kind) else {
            throw FileveroError.unsupported("This operation does not produce a single media preview.")
        }
        if kind == .splitVideo, !options.joinSplitClips {
            throw FileveroError.invalidInput("Choose Export One Video to preview the retained clips together.")
        }
        try checkCancellation(token)
        let directory = try OutputFiles.temporaryDirectory()
        do {
            var settings = options
            settings.outputDirectory = directory
            settings.revealInFinder = false
            let outputs = try await MediaTranscodePipeline.toolAsync(
                kind, inputs: [input], options: settings, token: token)
            guard outputs.count == 1, let output = outputs.first else {
                throw FileveroError.failed("The preview did not produce a single media file.")
            }
            let prepared = try await prepare(output, token: token)
            if let proxyDirectory = prepared.ownedTemporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
                return MediaPreviewResult(
                    originalURL: input, playbackURL: prepared.playbackURL, ownedTemporaryDirectory: proxyDirectory)
            }
            return MediaPreviewResult(originalURL: input, playbackURL: output, ownedTemporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func bleepPreview(
        _ input: URL, options: OperationOptions = .init(), token: CancellationToken = .init()
    ) async throws -> MediaPreviewResult {
        try await processedPreview(.redactAudio, input: input, options: options, token: token)
    }

    public static func visualizationPreview(
        _ input: URL, options: OperationOptions = .init(), maximumDuration: Double = 12,
        token: CancellationToken = .init()
    ) async throws -> MediaPreviewResult {
        try checkCancellation(token)
        guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 60 else {
            throw FileveroError.invalidInput("Preview duration must be between 0 and 60 seconds.")
        }
        let width = options.width ?? 1920
        let height = options.height ?? 1080
        guard (16...8192).contains(width), (16...8192).contains(height) else {
            throw FileveroError.invalidInput("Visualization dimensions must be between 16 and 8,192 pixels.")
        }
        let directory = try OutputFiles.temporaryDirectory()
        do {
            let audio = directory.appendingPathComponent("Preview Audio.wav")
            try await ExecutionPipeline.runAsync(
                Dependencies.executable("ffmpeg"),
                [
                    "-hide_banner", "-nostdin", "-v", "error", "-n", "-i", input.path, "-t", String(maximumDuration),
                    "-map", "0:a:0", "-vn", "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", audio.path,
                ], token: token)
            var settings = options
            let scale = min(1, 640 / Double(max(width, height)))
            settings.width = max(16, Int(Double(width) * scale) / 2 * 2)
            settings.height = max(16, Int(Double(height) * scale) / 2 * 2)
            settings.outputDirectory = directory
            settings.revealInFinder = false
            guard
                let output = try await MediaTranscodePipeline.toolAsync(
                    .audioToVideo, inputs: [audio], options: settings, token: token
                ).first
            else { throw FileveroError.failed("Could not create the visualization preview.") }
            try? FileManager.default.removeItem(at: audio)
            let prepared = try await prepare(output, token: token)
            if let proxy = prepared.ownedTemporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
                return MediaPreviewResult(
                    originalURL: input, playbackURL: prepared.playbackURL, ownedTemporaryDirectory: proxy)
            }
            return MediaPreviewResult(originalURL: input, playbackURL: output, ownedTemporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func nativelyPlayable(_ input: URL, token: CancellationToken) async throws -> Bool {
        do {
            let asset = AVURLAsset(url: input)
            guard try await asset.load(.isPlayable) else {
                try checkCancellation(token)
                return false
            }
            let tracks = try await asset.load(.tracks)
            var hasMedia = false
            for track in tracks where track.mediaType == .video || track.mediaType == .audio {
                hasMedia = true
                guard try await track.load(.isDecodable) else {
                    try checkCancellation(token)
                    return false
                }
            }
            try checkCancellation(token)
            return hasMedia
        } catch {
            try checkCancellation(token)
            return false
        }
    }

    private static func checkCancellation(_ token: CancellationToken) throws {
        if Task.isCancelled { throw FileveroError.cancelled }
        try token.check()
    }
}

// MARK: - Compatibility Bridge
public typealias MediaPreviewEngine = MediaAssetInspector

