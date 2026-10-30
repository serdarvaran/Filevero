import AVFoundation
import AppKit
import FileveroCore
import SwiftUI

// MARK: - MediaTimelineScrubber: Timeline Lanes, Thumbnails & Range Scrubber

public struct MediaTimelineScrubber: View {
    public let duration: Double
    public let current: Double
    public var ranges: [TimeRange]
    public var label: String
    public var source: URL? = nil
    public var thumbnails = false
    public var onSeek: (Double) -> Void
    public var onChange: (Int, TimeRange) -> Void
    public var onAdd: ((TimeRange) -> Void)? = nil

    @State private var pending: TimeRange?

    public init(
        duration: Double,
        current: Double,
        ranges: [TimeRange],
        label: String,
        source: URL? = nil,
        thumbnails: Bool = false,
        onSeek: @escaping (Double) -> Void,
        onChange: @escaping (Int, TimeRange) -> Void,
        onAdd: ((TimeRange) -> Void)? = nil
    ) {
        self.duration = duration
        self.current = current
        self.ranges = ranges
        self.label = label
        self.source = source
        self.thumbnails = thumbnails
        self.onSeek = onSeek
        self.onChange = onChange
        self.onAdd = onAdd
    }

    public var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(duration, 0.001)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if thumbnails, let source {
                    VideoThumbnailStrip(source: source, duration: duration)
                }
                ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                    MediaRangeClip(label: label)
                        .frame(width: max(14, (range.end - range.start) * scale), height: geometry.size.height)
                        .offset(x: range.start * scale)
                }
                if let pending {
                    Rectangle()
                        .fill(FileveroPalette.accent.opacity(0.3))
                        .frame(width: max(1, (pending.end - pending.start) * scale))
                        .offset(x: pending.start * scale)
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: min(geometry.size.width - 2, max(0, current * scale)))
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                MediaRangeGestureHandler(
                    duration: duration,
                    ranges: ranges,
                    label: label,
                    onSeek: onSeek,
                    onChange: onChange,
                    onPending: { pending = $0 },
                    onAdd: onAdd)
            }
            .clipped()
            .cornerRadius(6)
        }
        .frame(height: thumbnails ? 68 : 32)
    }
}

private struct MediaRangeClip: View {
    let label: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(FileveroPalette.accent.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(FileveroPalette.accent, lineWidth: 2))
            LText(label)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
            HStack(spacing: 0) {
                handle(start: true)
                Spacer(minLength: 0)
                handle(start: false)
            }
        }
    }

    func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(FileveroPalette.accent)
            .frame(width: 12)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 15))
            .accessibilityLabel(start ? "Range start" : "Range end")
    }
}

public struct VideoFrameThumbnail: View {
    public let source: URL
    public let time: Double
    @State private var thumbnail: NSImage?

    public init(source: URL, time: Double) {
        self.source = source
        self.time = time
    }

    public var body: some View {
        ZStack {
            Color.black
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: "\(source.path):\(time)") {
            let url = source
            let seconds = time
            let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 220, height: 150)
                return try? generator.copyCGImage(
                    at: CMTime(seconds: max(0, seconds), preferredTimescale: 60_000), actualTime: nil)
            }.value
            if !Task.isCancelled, let cgImage {
                thumbnail = NSImage(cgImage: cgImage, size: .zero)
            }
        }
        .accessibilityLabel("Frame at \(String(format: "%.2f", time)) seconds")
    }
}

public struct VideoThumbnailStrip: View {
    public let source: URL
    public let duration: Double

    public init(source: URL, duration: Double) {
        self.source = source
        self.duration = duration
    }

    public var body: some View {
        GeometryReader { geometry in
            let count = 8
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    VideoFrameThumbnail(source: source, time: duration * Double(index) / Double(count))
                        .frame(width: geometry.size.width / Double(count), height: geometry.size.height)
                }
            }
        }
        .clipped()
    }
}

public struct VideoPointTimeline: View {
    public let source: URL
    public let duration: Double
    public let current: Double
    public let points: [Double]
    public var onSeek: (Double) -> Void
    public var onChange: (Int, Double) -> Void

    public init(
        source: URL,
        duration: Double,
        current: Double,
        points: [Double],
        onSeek: @escaping (Double) -> Void,
        onChange: @escaping (Int, Double) -> Void
    ) {
        self.source = source
        self.duration = duration
        self.current = current
        self.points = points
        self.onSeek = onSeek
        self.onChange = onChange
    }

    public var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(duration, 0.001)
            ZStack(alignment: .topLeading) {
                VideoThumbnailStrip(source: source, duration: duration)
                Color.clear.contentShape(Rectangle()).gesture(
                    DragGesture(minimumDistance: 0).onChanged {
                        onSeek(max(0, min(duration, $0.location.x / scale)))
                    })
                ForEach(Array(points.enumerated()), id: \.offset) { index, time in
                    MediaPointMarker(time: time, duration: duration, scale: scale, onChange: { onChange(index, $0) })
                        .offset(x: time * scale - 4)
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: current * scale)
                    .allowsHitTesting(false)
            }
            .clipped()
            .cornerRadius(6)
        }
        .frame(height: 68)
    }
}

private struct MediaPointMarker: View {
    let time: Double
    let duration: Double
    let scale: CGFloat
    let onChange: (Double) -> Void
    @State private var initial: Double?

    var body: some View {
        Rectangle()
            .fill(FileveroPalette.accent)
            .frame(width: 8)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 15))
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if initial == nil { initial = time }
                    onChange(max(0.001, min(duration - 0.001, (initial ?? time) + value.translation.width / scale)))
                }.onEnded { _ in initial = nil }
            )
            .accessibilityLabel("Split at \(String(format: "%.2f", time)) seconds")
    }
}

// MARK: - Compatibility Bridge
public typealias MediaTimeRangeLane = MediaTimelineScrubber

