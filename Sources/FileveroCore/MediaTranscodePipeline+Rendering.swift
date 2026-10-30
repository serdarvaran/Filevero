import Foundation

extension MediaTranscodePipeline {
    static func visualization(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireAudio(info)
        let width = options.width ?? 1280
        let height = options.height ?? 720
        guard width >= 16, height >= 16, width <= 8192, height <= 8192 else {
            throw FileveroError.invalidInput("Visualization dimensions must be between 16 and 8,192 pixels.")
        }
        let w = width / 2 * 2
        let h = height / 2 * 2
        if ["image", "still", "still image"].contains(options.visualizationStyle.lowercased()) {
            guard let image = options.visualizationImage else {
                throw FileveroError.invalidInput("Choose a still image for the video.")
            }
            try validateInput(image, token: token)
            let color = try ffmpegColor(options.backgroundColor)
            let out = try outputURL(input, ext: "mp4", suffix: " Visualization", options: options)
            let filter =
                "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=\(color),setsar=1"
            try render(
                [
                    "-loop", "1", "-framerate", "30", "-i", image.path, "-i", input.path, "-map", "0:v:0", "-map",
                    "1:a:0", "-vf", filter, "-t", decimal(info.duration), "-shortest",
                ] + videoEncoding("mp4", quality: options.quality, sourceAudio: info.audio), to: out, token: token,
                duration: info.duration, progress: progress)
            return [out]
        }
        let visual: String
        switch options.visualizationStyle.lowercased() {
        case "waveform", "wave":
            visual = "showwaves=s=\(w)x\(h):mode=cline:rate=30:colors=0xff5200:scale=sqrt:draw=full"
        case "spectrum", "spectrogram":
            visual = "showspectrum=s=\(w)x\(h):mode=combined:slide=scroll:color=intensity:scale=log:fps=30"
        case "bars", "frequency":
            visual = "showfreqs=s=\(w)x\(h):mode=bar:ascale=log:fscale=log:colors=0xff830a:rate=30"
        default: throw FileveroError.invalidInput("Choose Waveform, Spectrum, Bars, or Still Image visualization.")
        }
        let out = try outputURL(input, ext: "mp4", suffix: " Visualization", options: options)
        let graph = "[0:a:0]asplit[visual][audio];[visual]\(visual),format=yuv420p[video]"
        try render(
            [
                "-i", input.path, "-filter_complex", graph, "-map", "[video]", "-map", "[audio]", "-t",
                decimal(info.duration), "-shortest",
            ] + videoEncoding("mp4", quality: options.quality, sourceAudio: info.audio), to: out, token: token,
            duration: info.duration, progress: progress)
        return [out]
    }

    static func channels(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireAudio(info)
        let filter = try channelFilter(info: info, options: options)
        let ext = audioExtension(input)
        let out = try outputURL(
            input, ext: audioExtension(input), suffix: options.channels == 1 ? " Mono" : " Stereo", options: options)
        try render(
            ["-i", input.path, "-map", "0:a:0", "-af", filter, "-ac", String(options.channels)]
                + audioEncoding(
                    ext, quality: options.quality, source: info.audio, channels: options.channels,
                    pcmCodec: try pcmCodec(for: ext, source: info.audio, setting: options.audioSampleDepth),
                    compressionPreset: options.compressionPreset), to: out, token: token, duration: info.duration,
            progress: progress)
        return [out]
    }

    static func channelFilter(info: MediaInfo, options: OperationOptions) throws -> String {
        guard options.channels == 1 || options.channels == 2, options.leftVolume.isFinite, options.rightVolume.isFinite,
            (0...4).contains(options.leftVolume), (0...4).contains(options.rightVolume)
        else { throw FileveroError.invalidInput("Choose mono or stereo and channel levels between 0% and 400%.") }
        let left = decimal(options.leftVolume)
        let right = decimal(options.rightVolume)
        let filter: String
        if info.audio?.channels == 1 {
            filter =
                options.channels == 1
                ? "volume=\(decimal((options.leftVolume + options.rightVolume) / 2))"
                : "pan=stereo|c0=\(left)*c0|c1=\(right)*c0"
        } else if options.channels == 1 {
            filter =
                "aformat=channel_layouts=stereo,pan=mono|c0=\(decimal(options.leftVolume / 2))*c0+\(decimal(options.rightVolume / 2))*c1"
        } else {
            filter = "aformat=channel_layouts=stereo,pan=stereo|c0=\(left)*c0|c1=\(right)*c1"
        }
        return filter
    }

    static func redactVideo(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireVideo(info)
        guard let video = info.video, let width = video.width, let height = video.height,
            !options.redactions.isEmpty || !options.videoRedactions.isEmpty
        else { throw FileveroError.invalidInput("Draw at least one area to redact.") }
        let selections =
            options.videoRedactions.isEmpty
            ? options.redactions.map { VideoRedaction(rect: $0, start: options.start, end: options.end) }
            : options.videoRedactions
        let mode = options.redactionMode.lowercased() == "black" ? "solid" : options.redactionMode.lowercased()
        guard ["blur", "solid", "pixelate", "pixelated"].contains(mode) else {
            throw FileveroError.invalidInput("Choose Solid, Blur, or Pixelate redaction.")
        }
        var graph: [String] = []
        var previous = try videoStream(info)
        for (index, selection) in selections.enumerated() {
            let rect =
                try mode == "solid"
                ? redactionPixelRect(selection.rect, width: width, height: height)
                : pixelRect(selection.rect, width: width, height: height)
            let range = try timeRange(selection.start, selection.end, duration: info.duration)
            let enable = "between(t,\(decimal(range.0)),\(decimal(range.1)))"
            let next = "redacted\(index)"
            if mode == "solid" {
                graph.append(
                    "[\(previous)]drawbox=x=\(rect.x):y=\(rect.y):w=\(rect.w):h=\(rect.h):color=\(try ffmpegColor(options.backgroundColor,opaque:true)):t=fill:enable='\(enable)'[\(next)]"
                )
            } else {
                let effect =
                    mode == "blur"
                    ? "gblur=sigma=20:steps=2"
                    : "scale=\(max(1, rect.w / 16)):\(max(1, rect.h / 16)):flags=neighbor,scale=\(rect.w):\(rect.h):flags=neighbor"
                graph.append(
                    "[\(previous)]split[base\(index)][crop\(index)];[crop\(index)]crop=\(rect.w):\(rect.h):\(rect.x):\(rect.y):exact=1,\(effect)[effect\(index)];[base\(index)][effect\(index)]overlay=\(rect.x):\(rect.y):enable='\(enable)'[\(next)]"
                )
            }
            previous = next
        }
        graph.append("[\(previous)]\(evenFramePad)[even]")
        let out = try outputURL(input, ext: videoExtension(input), suffix: " Redacted", options: options)
        try render(
            [
                "-i", input.path, "-filter_complex", graph.joined(separator: ";"), "-map", "[even]", "-map",
                "0:a:0?",
            ] + videoEncoding(out.pathExtension, quality: options.quality, copyAudio: true), to: out, token: token,
            duration: info.duration, progress: progress)
        return [out]
    }

    static func redactAudio(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireAudio(info)
        guard !options.audioRedactions.isEmpty else {
            throw FileveroError.invalidInput("Add at least one bleep range.")
        }
        let intervals = try options.audioRedactions.map { try timeRange($0.start, $0.end, duration: info.duration) }
        let expression = intervals.map { "between(t,\(decimal($0.0)),\(decimal($0.1)))" }.joined(separator: "+")
        let mode = options.audioMode.lowercased()
        guard ["bleep", "beep", "mute", "silence"].contains(mode) else {
            throw FileveroError.invalidInput("Choose Bleep or Mute audio redaction.")
        }
        let out = try outputURL(
            input, ext: audioExtension(input), suffix: mode == "mute" || mode == "silence" ? " Redacted" : " Bleeped",
            options: options)
        let replacement = mode == "mute" || mode == "silence" ? "0" : "0.18*sin(2*PI*1000*t)"
        let expressions = (0..<(info.audio?.channels ?? 2)).map { "if(\(expression),\(replacement),val(\($0)))" }
            .joined(separator: "|")
        var arguments = ["-i", input.path, "-map", "0:a:0", "-af", "aeval=exprs='\(expressions)':c=same"]
        arguments +=
            ["-ac", String(info.audio?.channels ?? 2), "-ar", String(info.audio?.sampleRate ?? 48000)]
            + audioEncoding(
                out.pathExtension, quality: options.quality, source: info.audio,
                pcmCodec: try pcmCodec(for: out.pathExtension, source: info.audio, setting: options.audioSampleDepth),
                compressionPreset: options.compressionPreset)
        try render(arguments, to: out, token: token, duration: info.duration, progress: progress)
        return [out]
    }

    static func compress(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard info.duration.isFinite, info.duration > 0, info.hasVideo || info.hasAudio else {
            throw FileveroError.invalidInput("Cannot compress media without a known duration.")
        }
        try validateQuality(options.quality)
        let target: Int64
        if let bytes = options.targetBytes {
            guard bytes > 0 else { throw FileveroError.invalidInput("Target file size must be positive.") }
            target = bytes
        } else if let percent = options.percentage {
            guard percent.isFinite, percent > 0, percent < 100 else {
                throw FileveroError.invalidInput("Percentage reduction must be greater than 0 and less than 100.")
            }
            target = Int64(Double(info.size) * (1 - percent / 100))
        } else {
            target = Int64(Double(info.size) * (0.35 + options.quality * 0.4))
        }
        guard target >= 2048 else {
            throw FileveroError.invalidInput(
                "The requested size is too small for a media container. Choose at least 2 KB.")
        }
        let video = info.hasVideo && !audioFormats.contains(input.pathExtension.lowercased())
        let ext =
            video
            ? videoExtension(input)
            : (["mp3", "m4a", "ogg", "opus", "wma", "aac"].contains(input.pathExtension.lowercased())
                ? input.pathExtension.lowercased() : "m4a")
        let out = try outputURL(input, ext: ext, suffix: " Compressed", options: options)
        let temp = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        var budget = max(1000, Double(target) * 0.93 - (video ? 2048 : 1024))
        var ownsOutput = false
        do {
            for attempt in 0..<6 {
                progress(OperationProgress.indeterminate, "Compression attempt \(attempt+1)…")
                let attemptProgress: ProgressHandler = { value, label in
                    progress(value, "Compression attempt \(attempt+1) · \(label)")
                }
                try token.check()
                let totalRate = min(500_000_000, budget * 8 / info.duration)
                let audioRate = info.hasAudio ? min(128000.0, max(8000, totalRate * (video ? 0.18 : 1))) : 0
                var arguments = ["-i", input.path, "-map_metadata", "-1", "-map_chapters", "-1"]
                if video {
                    let videoRate = max(1000, Int(totalRate - audioRate))
                    arguments += ["-map", try videoStream(info), "-map", "0:a:0?"]
                    if let scale = try scalingFilter(options) { arguments += ["-vf", scale] }
                    let codec =
                        ext == "webm" ? "libvpx-vp9" : ext == "wmv" ? "wmv2" : ext == "avi" ? "mpeg4" : "libx264"
                    arguments += ["-c:v", codec, "-b:v", String(videoRate), "-pix_fmt", "yuv420p"]
                    if codec == "libx264" { arguments += ["-preset", "medium"] }
                    let log = temp.appendingPathComponent("pass-\(attempt)").path
                    let firstPass = arguments + ["-an", "-pass", "1", "-passlogfile", log, "-f", "null", "/dev/null"]
                    try ffmpeg(
                        firstPass, token: token, overwrite: true, duration: info.duration,
                        progress: { value, _ in
                            attemptProgress(OperationProgress.map(value, from: 0, to: 0.5), "Analyzing video…")
                        })
                    arguments += ["-pass", "2", "-passlogfile", log]
                    if info.hasAudio {
                        arguments += audioEncoding(
                            ext == "webm" ? "opus" : ext == "wmv" ? "wma" : ext == "avi" ? "mp3" : "m4a",
                            quality: options.quality, bitrate: Int(audioRate), source: info.audio)
                    }
                    if ["mp4", "mov", "m4v"].contains(ext) { arguments += ["-movflags", "+faststart"] }
                } else {
                    arguments +=
                        ["-map", "0:a:0", "-vn"]
                        + audioEncoding(ext, quality: options.quality, bitrate: Int(audioRate), source: info.audio)
                    if audioRate < 24000 { arguments += ["-ac", "1", "-ar", "22050"] }
                }
                try render(
                    arguments, to: out, token: token, duration: info.duration,
                    progress: { value, _ in
                        attemptProgress(OperationProgress.map(value, from: video ? 0.5 : 0, to: 1), "Encoding…")
                    })
                ownsOutput = true
                let actual = Int64(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                if actual <= target { return [out] }
                try FileManager.default.removeItem(at: out)
                ownsOutput = false
                budget *= max(0.2, min(0.9, Double(target) / Double(actual) * 0.88))
            }
            throw FileveroError.failed(
                "The requested size cannot be reached with this format. Choose a larger target size or a smaller video resolution."
            )
        } catch {
            if ownsOutput { try? FileManager.default.removeItem(at: out) }
            throw error
        }
    }

    static func render(
        _ arguments: [String], to output: URL, token: CancellationToken, duration: Double? = nil,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws {
        let temporary = try renderStaging(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try ffmpeg(arguments + [temporary.path], token: token, duration: duration, progress: progress)
        } catch FileveroError.failed(let diagnostic) {
            let fallback = try vorbisRetry(arguments, after: diagnostic, staging: temporary, token: token)
            try ffmpeg(fallback + [temporary.path], token: token, duration: duration, progress: progress)
        }
        try publishRender(temporary, to: output, token: token)
    }

    static func renderAsync(
        _ arguments: [String], to output: URL, token: CancellationToken, duration: Double? = nil,
        progress: @escaping ProgressHandler = { _, _ in }
    ) async throws {
        let temporary = try renderStaging(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await ffmpegAsync(arguments + [temporary.path], token: token, duration: duration, progress: progress)
        } catch FileveroError.failed(let diagnostic) {
            let fallback = try vorbisRetry(arguments, after: diagnostic, staging: temporary, token: token)
            try await ffmpegAsync(fallback + [temporary.path], token: token, duration: duration, progress: progress)
        }
        try publishRender(temporary, to: output, token: token)
    }

    private static func renderStaging(for output: URL) throws -> URL {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FileveroError.failed("An output with this name already exists.")
        }
        return output.deletingLastPathComponent().appendingPathComponent(".filevero-\(UUID().uuidString)")
            .appendingPathExtension(output.pathExtension)
    }

    /// Returns the retry arguments when libvorbis rejected the quality setting; rethrows anything else.
    private static func vorbisRetry(
        _ arguments: [String], after diagnostic: String, staging: URL, token: CancellationToken
    ) throws -> [String] {
        guard diagnostic.contains("libvorbis"), diagnostic.contains("encoder setup failed"),
            let fallback = vorbisQualityFallback(arguments)
        else { throw FileveroError.failed(diagnostic) }
        try token.check()
        try? FileManager.default.removeItem(at: staging)
        return fallback
    }

    private static func publishRender(_ staging: URL, to output: URL, token: CancellationToken) throws {
        try token.check()
        try OutputFiles.validate([staging])
        try FileManager.default.moveItem(at: staging, to: output)
    }
}

