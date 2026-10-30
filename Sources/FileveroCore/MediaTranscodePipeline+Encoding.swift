import Foundation

extension MediaTranscodePipeline {
    static func outputURL(_ input: URL, ext: String, suffix: String = "", options: OperationOptions) throws
        -> URL
    {
        if let directory = options.outputDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return OutputFiles.unique(for: input, extension: ext, suffix: suffix, directory: options.outputDirectory)
    }

    static func audioEncoding(
        _ ext: String, quality: Double, bitrate: Int? = nil, source: MediaStream? = nil, channels: Int? = nil,
        pcmCodec: String? = nil, compressionPreset: String = "balanced"
    ) -> [String] {
        let rate = max(8000, bitrate ?? 192000)
        let channelCount = max(1, channels ?? source?.channels ?? 2)
        let sampleRate = max(1, source?.sampleRate ?? 48000)
        switch ext {
        case "mp3":
            let maximum = sampleRate <= 12000 ? 64000 : sampleRate < 32000 ? 160000 : 320000
            return ["-c:a", "libmp3lame", "-b:a", String(max(8000, min(maximum, rate / 8000 * 8000)))]
                + (channelCount > 2 ? ["-ac", "2"] : [])
        case "m4a", "aac":
            return ["-c:a", "aac", "-b:a", String(min(512000, min(rate, 6 * sampleRate * channelCount)))]
        case "wav": return ["-c:a", pcmCodec ?? "pcm_s16le"]
        case "aiff", "aif": return ["-c:a", pcmCodec ?? "pcm_s16be"]
        case "flac":
            return [
                "-c:a", "flac", "-compression_level",
                compressionPreset == "fast" ? "0" : compressionPreset == "maximum" ? "12" : "8",
            ]
        case "ogg": return ["-c:a", "libvorbis", "-b:a", String(max(32000, min(320000, rate)))]
        case "opus":
            let encoderRate = [48000, 24000, 16000, 12000, 8000].contains(sampleRate) ? sampleRate : 48000
            return [
                "-c:a", "libopus", "-b:a", String(min(512000, min(rate, 256000 * channelCount))), "-ar",
                String(encoderRate),
            ]
        case "wma":
            return [
                "-c:a", "wmav2", "-b:a", String(max(24000, min(320000, rate))), "-ar",
                String(max(8000, min(48000, sampleRate))),
            ] + (channelCount > 2 ? ["-ac", "2"] : [])
        default: return ["-c:a", "aac", "-b:a", String(rate)]
        }
    }

    static func vorbisQualityFallback(_ arguments: [String]) -> [String]? {
        guard let codec = arguments.firstIndex(of: "-c:a"), arguments.indices.contains(codec + 1),
            arguments[codec + 1] == "libvorbis",
            let bitrate = arguments.firstIndex(of: "-b:a"), arguments.indices.contains(bitrate + 1),
            let rate = Double(arguments[bitrate + 1])
        else { return nil }
        let levels: [(Double, Double)] = [
            (32000, -1), (64000, 0), (80000, 1), (96000, 2), (112000, 3), (128000, 4), (160000, 5), (192000, 6),
            (224000, 7), (256000, 8), (320000, 9),
        ]
        var quality = levels.last!.1
        if rate <= levels[0].0 {
            quality = levels[0].1
        } else {
            for (lower, upper) in zip(levels, levels.dropFirst()) where rate <= upper.0 {
                quality = lower.1 + (upper.1 - lower.1) * (rate - lower.0) / (upper.0 - lower.0)
                break
            }
        }
        var fallback = arguments
        fallback[bitrate] = "-q:a"
        fallback[bitrate + 1] = decimal(quality)
        return fallback
    }

    static func videoEncoding(
        _ ext: String, quality: Double, copyAudio: Bool = false, audioBitrate: Int = 192000,
        sourceAudio: MediaStream? = nil
    ) -> [String] {
        let crf = String(Int((1 - min(1, max(0, quality))) * 25 + 15))
        var arguments: [String]
        let audioFormat: String
        switch ext {
        case "webm":
            arguments = ["-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-deadline", "good", "-cpu-used", "2"]
            audioFormat = "opus"
        case "avi":
            arguments = ["-c:v", "mpeg4", "-q:v", String(max(2, Int((1 - quality) * 20 + 2)))]
            audioFormat = "mp3"
        case "wmv":
            arguments = ["-c:v", "wmv2", "-q:v", String(max(2, Int((1 - quality) * 20 + 2)))]
            audioFormat = "wma"
        default:
            arguments = ["-c:v", "libx264", "-preset", "medium", "-crf", crf]
            audioFormat = "m4a"
        }
        arguments += ["-pix_fmt", "yuv420p"]
        arguments +=
            copyAudio
            ? ["-c:a", "copy"]
            : audioEncoding(audioFormat, quality: quality, bitrate: audioBitrate, source: sourceAudio)
        if ["mp4", "mov", "m4v"].contains(ext) { arguments += ["-movflags", "+faststart"] }
        return arguments
    }

    /// yuv420p encoders such as libx264 reject odd frame sizes.
    static let evenFramePad = "pad=ceil(iw/2)*2:ceil(ih/2)*2"

    static func scalingFilter(_ options: OperationOptions) throws -> String? {
        if let width = options.width, width < 2 || width > 16384 {
            throw FileveroError.invalidInput("Width must be between 2 and 16,384 pixels.")
        }
        if let height = options.height, height < 2 || height > 16384 {
            throw FileveroError.invalidInput("Height must be between 2 and 16,384 pixels.")
        }
        var filter: String
        if let width = options.width, let height = options.height {
            let w = width / 2 * 2
            let h = height / 2 * 2
            filter = "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1"
        } else if let width = options.width {
            filter = "scale=\(width / 2 * 2):-2,setsar=1"
        } else if let height = options.height {
            filter = "scale=-2:\(height / 2 * 2),setsar=1"
        } else {
            filter = evenFramePad
        }
        if options.videoMaxHeight > 0 { filter += ",scale=-2:'trunc(min(\(options.videoMaxHeight),ih)/2)*2',setsar=1" }
        return filter
    }

    static func pcmCodec(for ext: String, source: MediaStream?, setting: String) throws -> String? {
        guard ["wav", "aiff", "aif"].contains(ext) else { return nil }
        let endian = ext == "wav" ? "le" : "be"
        switch setting {
        case "pcm16", "bit16": return "pcm_s16\(endian)"
        case "pcm24", "bit24": return "pcm_s24\(endian)"
        case "pcm32", "bit32": return "pcm_s32\(endian)"
        case "float32": return "pcm_f32\(endian)"
        case "matchSource":
            let codec = source?.codec ?? ""
            if codec.hasPrefix("pcm_f") {
                let depth = Int(codec.dropFirst(5).prefix(while: \.isNumber)) ?? 32
                return "pcm_f\(depth > 32 ? 64 : 32)\(endian)"
            }
            let rawDepth = [source?.bitsPerRawSample, source?.bitsPerSample].compactMap { $0 }.first { $0 > 0 }
            let codecDepth =
                codec.hasPrefix("pcm_s") || codec.hasPrefix("pcm_u")
                ? Int(codec.dropFirst(5).prefix(while: \.isNumber)) : nil
            let depth = codec == "pcm_alaw" || codec == "pcm_mulaw" ? 16 : (rawDepth ?? codecDepth ?? 16)
            guard depth <= 32 else {
                throw FileveroError.invalidInput(
                    "This source uses more than 32-bit integer audio. Choose an output bit depth in settings.")
            }
            if depth <= 8 { return ext == "wav" ? "pcm_u8" : "pcm_s8" }
            return "pcm_s\(depth <= 16 ? 16 : depth <= 24 ? 24 : 32)\(endian)"
        default:
            throw FileveroError.invalidInput(
                "Choose Match Source, 16-bit, 24-bit, 32-bit integer, or 32-bit float audio.")
        }
    }

    static func tempoFilter(_ speed: Double) -> String {
        var rate = speed
        var factors: [Double] = []
        while rate > 2 {
            factors.append(2)
            rate /= 2
        }
        while rate < 0.5 {
            factors.append(0.5)
            rate /= 0.5
        }
        factors.append(rate)
        return factors.map { "atempo=\(decimal($0))" }.joined(separator: ",")
    }

    static func validateInput(_ url: URL, token: CancellationToken) throws {
        try token.check()
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw FileveroError.invalidInput("Choose a readable local media file.") }
    }

    static func requireAudio(_ info: MediaInfo) throws {
        guard info.hasAudio else { throw FileveroError.invalidInput("The file has no audio track.") }
    }

    static func requireVideo(_ info: MediaInfo) throws {
        guard info.hasVideo else { throw FileveroError.invalidInput("The file has no video track.") }
    }

    /// `0:v:0` can select embedded cover art that precedes the real video, so map the stream by absolute index.
    static func videoStream(_ info: MediaInfo, input: Int = 0) throws -> String {
        guard let video = info.video else { throw FileveroError.invalidInput("The file has no video track.") }
        return "\(input):\(video.index)"
    }

    static func validateQuality(_ quality: Double) throws {
        guard quality.isFinite, (0...1).contains(quality) else {
            throw FileveroError.invalidInput("Quality must be between 0 and 1.")
        }
    }

    static func validateMediaPreferences(_ options: OperationOptions) throws {
        guard [128, 192, 256, 320].contains(options.audioBitrate) else {
            throw FileveroError.invalidInput("Choose an audio bitrate of 128, 192, 256, or 320 kbps.")
        }
        guard
            ["matchSource", "pcm16", "pcm24", "pcm32", "float32", "bit16", "bit24", "bit32"].contains(
                options.audioSampleDepth)
        else { throw FileveroError.invalidInput("Choose a supported audio sample depth.") }
        guard options.videoMaxHeight == 0 || (2...16384).contains(options.videoMaxHeight) else {
            throw FileveroError.invalidInput("Maximum video height must be Original or between 2 and 16,384 pixels.")
        }
        guard (1...60).contains(options.gifFrameRate), (2...16384).contains(options.gifMaxWidth) else {
            throw FileveroError.invalidInput("GIF frame rate must be 1–60 and maximum width 2–16,384 pixels.")
        }
        guard ["fast", "balanced", "maximum"].contains(options.compressionPreset) else {
            throw FileveroError.invalidInput("Choose Fast, Balanced, or Maximum compression.")
        }
        guard options.silenceThresholdDb.isFinite, (-80 ... -10).contains(options.silenceThresholdDb) else {
            throw FileveroError.invalidInput("Choose a silence threshold between −80 and −10 dB.")
        }
    }

    static func validateNormalization(target: Double, range: Double, peak: Double) throws {
        guard target.isFinite, (-70 ... -5).contains(target), range.isFinite, (1...50).contains(range), peak.isFinite,
            (-9...0).contains(peak)
        else {
            throw FileveroError.invalidInput(
                "Loudness must be −70 to −5 LUFS, range 1 to 50 LU, and true peak −9 to 0 dBTP.")
        }
    }

    static func timeRange(_ start: Double, _ end: Double?, duration: Double) throws -> (Double, Double) {
        let finish = end ?? duration
        guard start.isFinite, finish.isFinite, start >= 0, finish > start, duration <= 0 || finish <= duration + 0.001
        else {
            throw FileveroError.invalidInput("The start and end times must describe a nonempty range inside the media.")
        }
        return (start, min(finish, duration > 0 ? duration : finish))
    }

    static func pixelRect(_ rect: EditRect, width: Int, height: Int) throws -> (x: Int, y: Int, w: Int, h: Int) {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.x >= 0, rect.y >= 0,
            rect.width >= 2, rect.height >= 2, rect.x + rect.width <= Double(width) + 0.01,
            rect.y + rect.height <= Double(height) + 0.01
        else {
            throw FileveroError.invalidInput(
                "The selected rectangle must be inside the video and at least 2 × 2 pixels.")
        }
        return (Int(rect.x), Int(rect.y), Int(rect.width), Int(rect.height))
    }

    static func redactionPixelRect(_ rect: EditRect, width: Int, height: Int) throws -> (
        x: Int, y: Int, w: Int, h: Int
    ) {
        _ = try pixelRect(rect, width: width, height: height)
        let x = Int(floor(rect.x))
        let y = Int(floor(rect.y))
        let right = min(width, Int(ceil(rect.x + rect.width)))
        let bottom = min(height, Int(ceil(rect.y + rect.height)))
        return (x, y, right - x, bottom - y)
    }

    static func audioExtension(_ input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return audioFormats.contains(ext) ? ext : "m4a"
    }

    static func videoExtension(_ input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return videoFormats.contains(ext) && ext != "gif" ? ext : "mp4"
    }

    static func ffmpegColor(_ color: String, opaque: Bool = false) throws -> String {
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard [6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else {
            throw FileveroError.invalidInput("Use a six- or eight-digit hexadecimal color.")
        }
        return "0x" + (opaque ? String(hex.prefix(6)) : hex)
    }

    static func metadataArguments(_ metadata: [String: String]) -> [String] {
        metadata.sorted { $0.key < $1.key }.flatMap { ["-metadata", "\($0.key)=\($0.value)"] }
    }

    static func metadataSpecifier(_ key: String) throws -> (String, String) {
        if key.hasPrefix("file:") { return ("-metadata", String(key.dropFirst(5))) }
        for (prefix, scope) in [("track[", "s"), ("chapter[", "c")] where key.hasPrefix(prefix) {
            guard let close = key.range(of: "]:"),
                let index = Int(key[key.index(key.startIndex, offsetBy: prefix.count)..<close.lowerBound]), index >= 0
            else { throw FileveroError.invalidInput("Invalid metadata location: \(key)") }
            return ("-metadata:\(scope):\(index)", String(key[close.upperBound...]))
        }
        return ("-metadata", key)
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value).replacingOccurrences(
            of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        number(value).flatMap { $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil }
    }

    static func fraction(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/").compactMap { Double($0) }
        let result = parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : Double(value)
        return result.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    static func tags(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        return raw.mapValues { String(describing: $0) }
    }
}

