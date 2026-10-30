import AVKit
import AppKit
import FileveroCore
import PDFKit
import SwiftUI

// MARK: - ToolWorkbench Preview & Canvas Presentation

extension ToolWorkbench {
    var imagePreview: some View {
        ImageEditPreview(
            image: showOriginal ? baseImage.map { NSImage(cgImage: $0, size: .zero) } : image,
            imageSize: showOriginal ? imageSize : (previewSize ?? imageSize),
            crop: tool == .cropImage ? options.crop : nil,
            redactions: options.redactions,
            annotations: options.imageAnnotations,
            redactionColor: Color(cgColor: ImageEngine.color(options.backgroundColor).copy(alpha: 1)!),
            zoom: previewZoom,
            onStroke: tool == .annotateImage && !selectingAnnotations ? addAnnotation : nil,
            onMoveAnnotation: { i, r, points in
                options.imageAnnotations[i].rect = r
                options.imageAnnotations[i].points = points
            },
            onMoveRedaction: { i, r in options.redactions[i] = r },
            onMoveCrop: { r in setCrop(r) },
            cropEnabled: tool == .cropImage,
            cropAspectRatio: cropAspectRatio,
            onCropInteraction: cropInteraction,
            annotationStyle: tool == .annotateImage ? annotationStyle : nil,
            annotationSource: baseImage,
            selectAnnotations: selectingAnnotations
        ) { rect in
            switch tool {
            case .cropImage: setCrop(rect)
            case .redactImage: options.redactions.append(rect)
            case .annotateImage: break
            default: break
            }
        }
        .frame(height: 420)
        .background(Color.black.opacity(0.94))
        .cornerRadius(20)
    }

    var mediaPreview: some View {
        VStack(spacing: 10) {
            if let player {
                ZStack {
                    PlayerView(
                        player: player,
                        onTime: updatePlayhead,
                        onPlayback: { isPlaying = $0 },
                        hiddenControls: true
                    )
                    .id(ObjectIdentifier(player))
                    .frame(height: audio && tool != .audioToVideo ? 0 : 330)

                    if (tool == .cropVideo || tool == .redactVideo) && !processedPlayback {
                        ImageEditPreview(
                            image: nil,
                            imageSize: imageSize,
                            crop: tool == .cropVideo ? options.crop : nil,
                            redactions: options.redactions,
                            annotations: [],
                            redactionColor: Color(cgColor: ImageEngine.color(options.backgroundColor).copy(alpha: 1)!),
                            activeRedactions: tool == .redactVideo ? activeVideoRegions : nil,
                            onMoveRedaction: { i, r in
                                options.redactions[i] = r
                                if options.videoRedactions.indices.contains(i) {
                                    options.videoRedactions[i].rect = r
                                }
                            },
                            onMoveCrop: setCrop,
                            cropEnabled: tool == .cropVideo,
                            cropAspectRatio: cropAspectRatio,
                            onCropInteraction: cropInteraction
                        ) { rect in
                            if tool == .cropVideo {
                                setCrop(rect)
                            } else {
                                options.redactions.append(rect)
                                options.videoRedactions.append(
                                    VideoRedaction(rect: rect, start: options.start, end: options.end))
                            }
                        }
                        .frame(height: 330)
                    }
                }
                .cornerRadius(10)
            }

            if tool == .audioToVideo {
                if previewBusy {
                    ProgressView("Preparing visualization…")
                }
                if visualizationReady {
                    Text("Preview uses the first 12 seconds. Export includes the full recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !(tool == .splitVideo && processedPlayback) {
                mediaTimeline
            }

            if audio && tool != .audioToVideo {
                if waveform.isEmpty {
                    ProgressView("Reading waveform…").frame(height: 80)
                } else if tool == .audioChannels, !leftWaveform.isEmpty {
                    channelWaveform("L", peaks: leftWaveform, gain: options.leftVolume)
                    channelWaveform("R", peaks: rightWaveform, gain: options.rightVolume)
                } else {
                    AudioWaveformView(
                        peaks: processedWaveform ?? waveform,
                        duration: duration,
                        current: playhead,
                        selection: tool == .trimAudio
                            ? TimeRange(start: options.start, end: options.end ?? duration) : nil,
                        redactions: options.audioRedactions,
                        rangeEnabled: tool == .trimAudio || tool == .redactAudio,
                        onSeek: seek,
                        onRange: { start, end in
                            options.start = start
                            options.end = end
                            if tool == .redactAudio {
                                options.audioRedactions.append(TimeRange(start: start, end: end))
                            }
                        }
                    )
                    .frame(height: 90)
                }
            }

            if duration > 0 {
                Slider(
                    value: Binding(get: { min(playhead, playbackDuration) }, set: seek),
                    in: 0...max(0.001, playbackDuration)
                )
                .tint(FileveroPalette.accent)
            }

            HStack {
                Button {
                    seek(max(0, playhead - 1 / frameRate))
                } label: {
                    Image(systemName: "backward.end")
                }
                .accessibilityLabel("Previous frame")
                .help("Previous frame")

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .help("Play / Pause (Space)")

                Button {
                    seek(min(playbackDuration, playhead + 1 / frameRate))
                } label: {
                    Image(systemName: "forward.end")
                }
                .accessibilityLabel("Next frame")
                .help("Next frame")

                Spacer()

                Text("\(timeLabel(playhead)) / \(timeLabel(playbackDuration))")
                    .font(.caption.monospacedDigit())
            }

            if (audio && tool != .audioToVideo && tool != .trimAudio) || tool == .redactVideo {
                HStack {
                    Button("Original") { playOriginal() }
                    Button(previewBusy ? "Preparing…" : "Preview Processed") {
                        processedPreview()
                    }
                    .disabled(previewBusy || (tool == .redactVideo || tool == .redactAudio) && !canApply)
                }
            }

            if tool == .redactVideo, processedPlayback {
                Text("Processed preview. Choose Original to edit areas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tool == .trimAudio || tool == .trimVideo {
                Button("Play Selected Range", action: playSelectedRange)
                    .help("Play selected range (⇧Space)")
            }

            LText(mediaShortcutHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var playbackDuration: Double {
        if processedPlayback, let processedDuration { return processedDuration }
        return tool == .audioToVideo && visualizationReady ? min(duration, 12) : duration
    }

    var activeVideoRegions: Set<Int> {
        options.redactionMode == "blur"
            ? []
            : Set(
                options.videoRedactions.enumerated().filter {
                    playhead >= $0.element.start && playhead < ($0.element.end ?? duration)
                }.map { $0.offset })
    }

    var compressionResultText: String {
        func bytes(_ urls: [URL]) -> Int64 {
            urls.reduce(0) {
                $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
        let before = bytes(inputs)
        let after = bytes(state.outputs)
        if before == after { return "Already optimized. Original quality retained." }
        let size = ByteCountFormatter.string(fromByteCount: after, countStyle: .file)
        return before > after && before > 0
            ? "\(size) · \(Int((1 - Double(after) / Double(before)) * 100))% smaller" : "Saved size: \(size)"
    }

    @ViewBuilder var mediaTimeline: some View {
        if duration > 0 {
            if tool == .trimVideo || tool == .trimAudio {
                MediaTimeRangeLane(
                    duration: duration,
                    current: playhead,
                    ranges: [TimeRange(start: options.start, end: options.end ?? duration)],
                    label: "Trim",
                    source: playbackURL ?? input,
                    thumbnails: tool == .trimVideo,
                    onSeek: seek,
                    onChange: { _, range in
                        options.start = range.start
                        options.end = range.end
                    })
            } else if tool == .redactAudio {
                Text("Drag a range to move it; drag its edges to resize. Drag empty space to add.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MediaTimeRangeLane(
                    duration: duration,
                    current: playhead,
                    ranges: options.audioRedactions,
                    label: options.audioMode == "mute" ? "Mute" : "Bleep",
                    onSeek: seek,
                    onChange: { i, r in options.audioRedactions[i] = r },
                    onAdd: { options.audioRedactions.append($0) })
            } else if tool == .redactVideo {
                ForEach(Array(options.videoRedactions.enumerated()), id: \.offset) { i, r in
                    HStack {
                        LText("Area \(i+1)").font(.caption).frame(width: 45)
                        MediaTimeRangeLane(
                            duration: duration,
                            current: playhead,
                            ranges: [TimeRange(start: r.start, end: r.end ?? duration)],
                            label: "",
                            onSeek: seek,
                            onChange: { _, range in
                                options.videoRedactions[i].start = range.start
                                options.videoRedactions[i].end = range.end
                            })
                    }
                }
            } else if let source = playbackURL ?? input, tool == .splitVideo || tool == .videoSnapshots {
                VideoPointTimeline(
                    source: source,
                    duration: duration,
                    current: playhead,
                    points: tool == .splitVideo ? options.splitPoints : [],
                    onSeek: seek,
                    onChange: { i, time in
                        options.equalClips = nil
                        let lower = i > 0 ? options.splitPoints[i - 1] + 0.05 : 0.05
                        let upper =
                            i + 1 < options.splitPoints.count ? options.splitPoints[i + 1] - 0.05 : duration - 0.05
                        options.splitPoints[i] = min(max(time, lower), max(lower, upper))
                    })
            }
        }
    }

    func channelWaveform(_ title: String, peaks: [Float], gain: Double) -> some View {
        HStack {
            LText(title).font(.caption.bold()).frame(width: 15)
            AudioWaveformView(
                peaks: peaks.map { min(1, $0 * Float(gain)) },
                duration: duration,
                current: playhead,
                selection: nil,
                redactions: [],
                rangeEnabled: false,
                onSeek: seek,
                onRange: { _, _ in }
            ).frame(height: 50)
        }
    }
}

