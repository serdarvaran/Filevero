import Foundation

extension MediaTranscodePipeline {
    static func normalize(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireAudio(info)
        let measurement = try measureLoudness(
            input, target: options.targetLoudness, range: options.loudnessRange, peak: options.truePeak, token: token,
            progress: { value, label in progress(OperationProgress.map(value, from: 0, to: 0.45), label) })
        var filter =
            "loudnorm=I=\(decimal(options.targetLoudness)):LRA=\(decimal(options.loudnessRange)):TP=\(decimal(options.truePeak))"
        if [
            measurement.integrated, measurement.truePeak, measurement.targetOffset, measurement.range,
            measurement.threshold,
        ].allSatisfy(\.isFinite) {
            filter +=
                ":measured_I=\(decimal(measurement.integrated)):measured_TP=\(decimal(measurement.truePeak)):measured_LRA=\(decimal(measurement.range)):measured_thresh=\(decimal(measurement.threshold)):offset=\(decimal(measurement.targetOffset)):linear=true"
        }
        let ext = audioExtension(input)
        let out = try outputURL(input, ext: ext, suffix: " Normalized", options: options)
        try render(
            ["-i", input.path, "-map", "0:a:0", "-af", filter, "-ar", String(info.audio?.sampleRate ?? 48000)]
                + audioEncoding(
                    ext, quality: options.quality, source: info.audio,
                    pcmCodec: try pcmCodec(for: ext, source: info.audio, setting: options.audioSampleDepth),
                    compressionPreset: options.compressionPreset), to: out, token: token, duration: info.duration,
            progress: { value, label in progress(OperationProgress.map(value, from: 0.45, to: 1), label) })
        return [out]
    }

    static func trim(
        _ input: URL, info: MediaInfo, audio: Bool, options: OperationOptions, token: CancellationToken,
        suffix: String = " Trimmed", progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        if audio { try requireAudio(info) } else { try requireVideo(info) }
        let interval = try timeRange(options.start, options.end, duration: info.duration)
        let ext = audio ? audioExtension(input) : videoExtension(input)
        let out = try outputURL(input, ext: ext, suffix: suffix, options: options)
        var arguments = ["-i", input.path, "-ss", decimal(interval.0), "-t", decimal(interval.1 - interval.0)]
        if audio {
            arguments += ["-map", "0:a:0", "-vn"]
            if options.trimSilence {
                arguments += [
                    "-af",
                    "silenceremove=start_periods=1:start_duration=0.02:start_threshold=\(decimal(options.silenceThresholdDb))dB,areverse,silenceremove=start_periods=1:start_duration=0.02:start_threshold=\(decimal(options.silenceThresholdDb))dB,areverse",
                ]
            }
            arguments += audioEncoding(
                ext, quality: options.quality, source: info.audio,
                pcmCodec: try pcmCodec(for: ext, source: info.audio, setting: options.audioSampleDepth),
                compressionPreset: options.compressionPreset)
        } else {
            arguments +=
                ["-map", try videoStream(info), "-map", "0:a:0?", "-vf", evenFramePad]
                + videoEncoding(ext, quality: options.quality, sourceAudio: info.audio)
        }
        try render(
            arguments, to: out, token: token, duration: audio && options.trimSilence ? nil : interval.1 - interval.0,
            progress: progress)
        return [out]
    }

    static func crop(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireVideo(info)
        guard let video = info.video, let width = video.width, let height = video.height else {
            throw FileveroError.invalidInput("The video has no readable dimensions.")
        }
        let requested =
            options.crop
            ?? EditRect(x: 0, y: 0, width: Double(options.width ?? width), height: Double(options.height ?? height))
        let rect = try pixelRect(requested, width: width, height: height)
        let out = try outputURL(input, ext: videoExtension(input), suffix: " Cropped", options: options)
        let filter = "crop=\(rect.w):\(rect.h):\(rect.x):\(rect.y):exact=1,\(evenFramePad)"
        try render(
            ["-i", input.path, "-map", try videoStream(info), "-map", "0:a:0?", "-vf", filter]
                + videoEncoding(out.pathExtension, quality: options.quality, copyAudio: true), to: out, token: token,
            duration: info.duration, progress: progress)
        return [out]
    }

    static func changeSpeed(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireVideo(info)
        guard options.speed.isFinite, options.speed >= 0.05, options.speed <= 100 else {
            throw FileveroError.invalidInput("Playback speed must be between 0.05× and 100×.")
        }
        let out = try outputURL(
            input, ext: videoExtension(input), suffix: " \(decimal(options.speed))x", options: options)
        var arguments = [
            "-i", input.path, "-map", try videoStream(info), "-map", "0:a:0?", "-vf",
            "setpts=(PTS-STARTPTS)/\(decimal(options.speed)),fps=\(decimal(info.video?.frameRate ?? 30)),\(evenFramePad)",
            "-fps_mode", "cfr",
        ]
        if info.hasAudio { arguments += ["-af", tempoFilter(options.speed)] }
        arguments += videoEncoding(out.pathExtension, quality: options.quality, sourceAudio: info.audio)
        try render(arguments, to: out, token: token, duration: info.duration / options.speed, progress: progress)
        return [out]
    }

    static func join(
        _ inputs: [URL], options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard inputs.count >= 2 else { throw FileveroError.invalidInput("Choose two or more videos to join.") }
        let infos = try inputs.map { try inspect($0, token: token) }
        try infos.forEach(requireVideo)
        guard let first = infos.first?.video else { throw FileveroError.invalidInput("The first clip has no video.") }
        let width = max(2, (first.width ?? 1280) / 2 * 2)
        let height = max(2, (first.height ?? 720) / 2 * 2)
        let fps = 30.0
        let audio = infos.contains { $0.hasAudio }
        let temp = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        var clips: [URL] = []
        for (index, input) in inputs.enumerated() {
            try token.check()
            let clip = temp.appendingPathComponent("clip-\(index).mp4")
            var arguments = ["-i", input.path]
            if audio && !infos[index].hasAudio { arguments += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"] }
            arguments += [
                "-map", try videoStream(infos[index]), "-vf",
                "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(decimal(fps)),setpts=PTS-STARTPTS",
            ]
            if audio {
                arguments += [
                    "-map", infos[index].hasAudio ? "0:a:0" : "1:a:0", "-af", "aresample=48000,asetpts=PTS-STARTPTS",
                    "-ac", "2", "-ar", "48000",
                ]
            } else {
                arguments += ["-an"]
            }
            arguments += ["-t", decimal(infos[index].duration)] + videoEncoding("mp4", quality: options.quality)
            try render(
                arguments, to: clip, token: token, duration: infos[index].duration,
                progress: { value, _ in
                    progress(
                        OperationProgress.map(
                            value, from: Double(index) / Double(inputs.count) * 0.95,
                            to: Double(index + 1) / Double(inputs.count) * 0.95),
                        "Joining clip \(index+1) of \(inputs.count)…")
                })
            clips.append(clip)
        }
        let list = temp.appendingPathComponent("clips.txt")
        try clips.map { "file '\($0.lastPathComponent)'\n" }.joined().write(to: list, atomically: true, encoding: .utf8)
        let out = try outputURL(inputs[0], ext: "mp4", suffix: " Joined", options: options)
        try render(
            ["-f", "concat", "-safe", "1", "-i", list.path, "-map", "0", "-c", "copy", "-movflags", "+faststart"],
            to: out, token: token, duration: infos.map(\.duration).reduce(0, +),
            progress: { value, _ in progress(OperationProgress.map(value, from: 0.95, to: 1), "Joining clips…") })
        return [out]
    }

    static func joinAudio(
        _ inputs: [URL], options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard inputs.count >= 2 else { throw FileveroError.invalidInput("Choose two or more audio files to join.") }
        let infos = try inputs.map { try inspect($0, token: token) }
        try infos.forEach(requireAudio)
        var arguments: [String] = []
        for input in inputs { arguments += ["-i", input.path] }
        let chains = inputs.indices.map { "[\($0):a:0]aresample=48000,aformat=channel_layouts=stereo[a\($0)]" }.joined(
            separator: ";")
        let filter = chains + ";" + inputs.indices.map { "[a\($0)]" }.joined() + "concat=n=\(inputs.count):v=0:a=1[out]"
        arguments += ["-filter_complex", filter, "-map", "[out]"] + audioEncoding("m4a", quality: options.quality)
        let out = try outputURL(inputs[0], ext: "m4a", suffix: " Joined", options: options)
        try render(arguments, to: out, token: token, duration: infos.map(\.duration).reduce(0, +), progress: progress)
        return [out]
    }

    static func slideshow(
        frames: URL, count: Int, secondsPerImage: Double, to output: URL, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws {
        let pattern = frames.appendingPathComponent("frame-%05d.png").path
        try render(
            ["-framerate", decimal(1 / secondsPerImage), "-i", pattern, "-vf", "fps=30,format=yuv420p"]
                + videoEncoding("mp4", quality: 0.8) + ["-an"], to: output, token: token,
            duration: secondsPerImage * Double(count), progress: progress)
    }

    static func snapshots(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireVideo(info)
        if let fraction = options.snapshotFraction {
            guard fraction.isFinite, (0...1).contains(fraction) else {
                throw FileveroError.invalidInput("Choose a position between 0% and 100%.")
            }
            var single = options
            single.snapshotFraction = nil
            single.snapshotTimes = [max(0, min(info.duration * fraction, info.duration - 0.5))]
            return try snapshots(input, info: info, options: single, token: token, progress: progress)
        }
        guard !options.snapshotTimes.isEmpty else {
            throw FileveroError.invalidInput("Choose at least one frame to save.")
        }
        var outputs: [URL] = []
        do {
            for (index, time) in options.snapshotTimes.enumerated() {
                guard time.isFinite, time >= 0, info.duration <= 0 || time < info.duration else {
                    throw FileveroError.invalidInput("A snapshot time is outside the video.")
                }
                let out = try outputURL(input, ext: "png", suffix: " Frame \(index + 1)", options: options)
                try render(
                    [
                        "-ss", decimal(time), "-i", input.path, "-map", try videoStream(info), "-frames:v", "1",
                        "-update", "1",
                        "-c:v", "png",
                    ], to: out, token: token)
                outputs.append(out)
                progress(
                    Double(index + 1) / Double(options.snapshotTimes.count),
                    "Saving frame \(index+1) of \(options.snapshotTimes.count)…")
            }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    static func split(
        _ input: URL, info: MediaInfo, options: OperationOptions, token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        try requireVideo(info)
        guard info.duration.isFinite, info.duration > 0 else {
            throw FileveroError.invalidInput("Cannot split a video with unknown duration.")
        }
        var points: [Double]
        if !options.splitPoints.isEmpty {
            guard options.splitPoints.allSatisfy({ $0.isFinite && $0 > 0 && $0 < info.duration }) else {
                throw FileveroError.invalidInput("Split points must fall inside the video.")
            }
            points = Array(Set(options.splitPoints)).sorted()
        } else if let count = options.equalClips {
            guard count >= 2, count <= 10000 else {
                throw FileveroError.invalidInput("Choose between 2 and 10,000 equal clips.")
            }
            points = (1..<count).map { info.duration * Double($0) / Double(count) }
        } else {
            guard options.splitInterval.isFinite, options.splitInterval > 0,
                info.duration / options.splitInterval <= 10000
            else { throw FileveroError.invalidInput("Enter a positive split interval producing at most 10,000 clips.") }
            points = stride(from: options.splitInterval, to: info.duration - 0.000001, by: options.splitInterval).map {
                $0
            }
        }
        let boundaries = [0] + points + [info.duration]
        guard zip(boundaries, boundaries.dropFirst()).allSatisfy({ $0.1 - $0.0 >= 0.05 - 0.000001 }) else {
            throw FileveroError.invalidInput("Split points must be at least 0.05 seconds apart and from either end.")
        }
        let discarded = Set(options.discardedClips)
        guard discarded.allSatisfy({ (0..<(boundaries.count - 1)).contains($0) }) else {
            throw FileveroError.invalidInput(
                "A removed clip is outside the current split segments. Restore the clips and try again.")
        }
        let retained = (0..<(boundaries.count - 1)).filter { !discarded.contains($0) }
        guard !retained.isEmpty else { throw FileveroError.invalidInput("Keep at least one clip to export.") }
        if options.joinSplitClips {
            let temporary = try OutputFiles.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let ext = videoExtension(input)
            var clips: [URL] = []
            for (position, index) in retained.enumerated() {
                var clipOptions = options
                clipOptions.outputDirectory = temporary
                clipOptions.start = boundaries[index]
                clipOptions.end = boundaries[index + 1]
                let rendered = try trim(
                    input, info: info, audio: false, options: clipOptions, token: token, suffix: " Part \(index + 1)",
                    progress: { value, _ in
                        progress(
                            OperationProgress.map(
                                value, from: Double(position) / Double(retained.count) * 0.95,
                                to: Double(position + 1) / Double(retained.count) * 0.95),
                            "Saving clip \(position+1) of \(retained.count)…")
                    })[0]
                let clip = temporary.appendingPathComponent("segment-\(index)").appendingPathExtension(ext)
                try FileManager.default.moveItem(at: rendered, to: clip)
                clips.append(clip)
            }
            let list = temporary.appendingPathComponent("clips.txt")
            let durations = retained.map { boundaries[$0 + 1] - boundaries[$0] }
            try zip(clips, durations).map { "file '\($0.0.lastPathComponent)'\nduration \(decimal($0.1))\n" }.joined()
                .write(to: list, atomically: true, encoding: .utf8)
            let out = try outputURL(input, ext: ext, suffix: " Split", options: options)
            var arguments = [
                "-f", "concat", "-safe", "1", "-i", list.path, "-map", "0", "-t", decimal(durations.reduce(0, +)), "-c",
                "copy",
            ]
            if ["mp4", "mov", "m4v"].contains(ext) { arguments += ["-movflags", "+faststart"] }
            try render(
                arguments, to: out, token: token, duration: durations.reduce(0, +),
                progress: { value, _ in
                    progress(OperationProgress.map(value, from: 0.95, to: 1), "Joining selected clips…")
                })
            return [out]
        }
        let destination = options.outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let folder = OutputFiles.unique(for: input, extension: "", suffix: " Clips", directory: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var outputs: [URL] = []
        do {
            for (position, index) in retained.enumerated() {
                var clipOptions = options
                clipOptions.outputDirectory = folder
                clipOptions.start = boundaries[index]
                clipOptions.end = boundaries[index + 1]
                outputs += try trim(
                    input, info: info, audio: false, options: clipOptions, token: token, suffix: " Part \(index + 1)",
                    progress: { value, _ in
                        progress(
                            OperationProgress.map(
                                value, from: Double(position) / Double(retained.count) * 0.95,
                                to: Double(position + 1) / Double(retained.count) * 0.95),
                            "Saving clip \(position+1) of \(retained.count)…")
                    })
            }
            return outputs
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

