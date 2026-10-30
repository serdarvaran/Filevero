import AVKit
import FileveroCore
import SwiftUI

// MARK: - ToolWorkbench Playback & Media Interaction

extension ToolWorkbench {
    func previewChannel(_ channel: Int) {
        guard let input, readyToApply, !isLoading else { return }
        let settings = options
        let token = previewToken
        let generation = editorGeneration
        Task {
            do {
                let url = try await MediaEngine.previewChannelAsync(
                    input, channel: channel, options: settings, token: token)
                guard generation == editorGeneration, !token.isCancelled else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                player?.pause()
                if let old = channelPreviewURL {
                    try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
                }
                channelPreviewURL = url
                playerReachedEnd = false
                player = AVPlayer(url: url)
                processedPlayback = true
                player?.play()
            } catch {
                if generation == editorGeneration, !token.isCancelled { previewError = error.localizedDescription }
            }
        }
    }

    var mediaShortcutHint: String {
        let fine = video ? "⇧←/→ 1 frame" : "⇧←/→ 0.1s"
        let extra =
            (tool == .trimAudio || tool == .trimVideo)
            ? " · I/O set range · ⇧Space play range"
            : tool == .splitVideo ? " · M add split" : tool == .videoSnapshots ? " · M add frame" : ""
        return "Space play/pause · ←/→ 1s · \(fine)\(extra)"
    }

    var canAddSplitPoint: Bool {
        !processedPlayback && playhead >= 0.05 && duration - playhead >= 0.05
            && !options.splitPoints.contains { abs($0 - playhead) < 0.05 }
    }

    func addSplitPoint() {
        guard canAddSplitPoint else { return }
        options.equalClips = nil
        options.splitPoints.append(playhead)
        options.splitPoints.sort()
    }

    func handleShortcut(_ command: EditorKeyboardCommand) -> Bool {
        guard !isLoading, readyToApply, !state.working else { return false }
        if command == .save {
            guard canApply else { return false }
            apply()
            return true
        }
        if command == .confirmCrop {
            guard isCropTool, canApply else { return false }
            apply()
            return true
        }
        guard audio || video, player != nil, !previewBusy else { return false }
        switch command {
        case .togglePlayback: togglePlayback()
        case .nudge(let direction, let fine):
            seek(
                EditorKeyboardCommand.seekTarget(
                    current: playhead, duration: playbackDuration, direction: direction, fine: fine, video: video,
                    frameRate: frameRate))
        case .beginning: seek(0)
        case .end: seek(playbackDuration)
        case .playRange:
            guard tool == .trimAudio || tool == .trimVideo else { return false }
            playSelectedRange()
        case .markIn:
            guard tool == .trimAudio || tool == .trimVideo else { return false }
            options.start = min(playhead, max(0, duration - 0.01))
            if (options.end ?? duration) <= options.start { options.end = duration }
        case .markOut:
            guard tool == .trimAudio || tool == .trimVideo else { return false }
            options.end = min(duration, max(0.01, playhead))
            if options.start >= (options.end ?? duration) { options.start = 0 }
        case .addMarker:
            guard !processedPlayback else { return false }
            if tool == .splitVideo {
                addSplitPoint()
            } else if tool == .videoSnapshots {
                options.snapshotTimes.append(playhead)
            } else {
                return false
            }
        case .save, .confirmCrop: break
        }
        return true
    }

    func playSelectedRange() {
        let end = options.end ?? duration
        guard options.start.isFinite, end.isFinite, options.start >= 0, end > options.start, end <= duration else {
            previewError = "Choose a valid start and end within the file’s duration."
            return
        }
        seek(options.start)
        playingRange = true
        player?.play()
    }

    func updatePlayhead(_ time: Double) {
        guard time.isFinite, !seeking else { return }
        if playingRange, time >= (options.end ?? duration) {
            player?.pause()
            seek(options.end ?? duration)
        } else {
            playhead = time
        }
    }

    func seek(_ value: Double) {
        guard value.isFinite, value >= 0, playbackDuration.isFinite else {
            previewError = "Enter a valid time within the file’s duration."
            return
        }
        let time = min(value, max(0, playbackDuration))
        playingRange = false
        playerReachedEnd = false
        playhead = time
        let revision = UUID()
        seekRevision = revision
        guard let player else {
            seeking = false
            return
        }
        seeking = true
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero
        ) { finished in
            DispatchQueue.main.async {
                guard seekRevision == revision, self.player === player else { return }
                seeking = false
                if finished { playhead = time }
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        var ended = playerReachedEnd
        if let end = player.currentItem?.duration.seconds, end.isFinite, player.currentTime().seconds >= end - 0.001 {
            ended = true
        }
        if player.rate != 0 && !ended {
            player.pause()
            return
        }
        if ended { seek(0) }
        if tool == .changeVideoSpeed {
            player.currentItem?.audioTimePitchAlgorithm = .spectral
            player.rate = Float(options.speed)
        } else {
            player.play()
        }
    }

    func playOriginal(play: Bool = true) {
        processedPlayback = false
        processedWaveform = nil
        processedDuration = nil
        if let url = playbackURL ?? input {
            let time = playhead
            player?.pause()
            player = AVPlayer(url: url)
            seek(time)
            if play {
                if time >= duration - 0.001 { seek(0) }
                player?.play()
            }
        }
    }

    func processedPreview() {
        guard let input, readyToApply, !isLoading else { return }
        var settings = options
        let kind = tool
        let token = previewToken
        let generation = editorGeneration
        if kind == .splitVideo { settings.joinSplitClips = true }
        previewBusy = true
        Task {
            do {
                let preview = try await MediaPreviewEngine.processedPreview(
                    kind, input: input, options: settings, token: token)
                guard generation == editorGeneration, !token.isCancelled else {
                    preview.removeTemporaryFiles()
                    return
                }
                let playbackURL = preview.playbackURL
                processedDuration = try? await MediaEngine.inspectAsync(playbackURL).duration
                guard generation == editorGeneration, !token.isCancelled else {
                    preview.removeTemporaryFiles()
                    return
                }
                player?.pause()
                if let old = channelPreviewURL {
                    try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
                }
                channelPreviewURL = preview.playbackURL
                playerReachedEnd = false
                player = AVPlayer(url: preview.playbackURL)
                processedPlayback = true
                player?.play()
                if kind == .normalizeAudio {
                    let url = preview.playbackURL
                    let peaks = try await MediaPreviewEngine.waveformPeaksAsync(url, token: token)
                    try checkGeneration(generation, token: token)
                    processedWaveform = peaks
                }
            } catch {
                if generation == editorGeneration, !token.isCancelled { previewError = error.localizedDescription }
            }
            if generation == editorGeneration, !token.isCancelled { previewBusy = false }
        }
    }

    var visualizationKey: String {
        tool == .audioToVideo
            ? "\(input?.path ?? ""):\(options.visualizationStyle):\(options.visualizationImage?.path ?? ""):\(options.backgroundColor):\(width):\(height)"
            : ""
    }

    func renderVisualization() async {
        guard tool == .audioToVideo, let input, width > 0, height > 0 else { return }
        if options.visualizationStyle == "image", options.visualizationImage == nil { return }
        visualizationToken.cancel()
        let token = CancellationToken()
        let generation = editorGeneration
        visualizationToken = token
        var settings = options
        settings.width = width
        settings.height = height
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
            try Task.checkCancellation()
            previewBusy = true
            let preview = try await withTaskCancellationHandler(
                operation: {
                    try await MediaPreviewEngine.visualizationPreview(input, options: settings, token: token)
                }, onCancel: { token.cancel() })
            if Task.isCancelled || token.isCancelled || generation != editorGeneration {
                preview.removeTemporaryFiles()
                return
            }
            player?.pause()
            if let old = channelPreviewURL { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
            channelPreviewURL = preview.playbackURL
            playerReachedEnd = false
            player = AVPlayer(url: preview.playbackURL)
            playhead = 0
            visualizationReady = true
            previewBusy = false
        } catch {
            if generation == editorGeneration, !Task.isCancelled, !token.isCancelled {
                previewBusy = false
                previewError = error.localizedDescription
            }
        }
    }

    func disposeMedia() {
        editorGeneration = UUID()
        readyToApply = false
        seekRevision = UUID()
        seeking = false
        isPlaying = false
        previewToken.cancel()
        visualizationToken.cancel()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let channelPreviewURL {
            try? FileManager.default.removeItem(at: channelPreviewURL.deletingLastPathComponent())
            self.channelPreviewURL = nil
        }
        if let mediaPreviewFolder {
            try? FileManager.default.removeItem(at: mediaPreviewFolder)
            self.mediaPreviewFolder = nil
        }
    }
}

