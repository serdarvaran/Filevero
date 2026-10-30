import AVKit
import AppKit
import FileveroCore
import SwiftUI

public struct WindowCloseButton: NSViewRepresentable {
    public final class Coordinator: NSObject {
        @objc public func close(_ sender: NSButton) {
            sender.window?.close()
        }
    }

    public init() {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
            target: context.coordinator,
            action: #selector(Coordinator.close(_:))
        )
        button.isBordered = false
        button.setAccessibilityLabel(L10n.text("Close"))
        return button
    }

    public func updateNSView(_ nsView: NSButton, context: Context) {}
}

public struct WindowDragRegion: NSViewRepresentable {
    public final class DragView: NSView {
        override public func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    public init() {}

    public func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.setAccessibilityElement(false)
        return view
    }

    public func updateNSView(_ view: DragView, context: Context) {}
}

public struct WindowIdentityReader: NSViewRepresentable {
    public var onWindow: (ObjectIdentifier) -> Void

    public init(onWindow: @escaping (ObjectIdentifier) -> Void) {
        self.onWindow = onWindow
    }

    public final class Reader: NSView {
        public var onWindow: ((ObjectIdentifier) -> Void)?
        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                let id = ObjectIdentifier(window)
                DispatchQueue.main.async { [weak self] in
                    self?.onWindow?(id)
                }
            }
        }
    }

    public func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onWindow = onWindow
        return view
    }

    public func updateNSView(_ nsView: Reader, context: Context) {
        nsView.onWindow = onWindow
    }
}

public struct PlayerView: NSViewRepresentable {
    public let player: AVPlayer
    public var onTime: (Double) -> Void = { _ in }
    public var onPlayback: (Bool) -> Void = { _ in }
    public var hiddenControls = false

    public init(
        player: AVPlayer,
        onTime: @escaping (Double) -> Void = { _ in },
        onPlayback: @escaping (Bool) -> Void = { _ in },
        hiddenControls: Bool = false
    ) {
        self.player = player
        self.onTime = onTime
        self.onPlayback = onPlayback
        self.hiddenControls = hiddenControls
    }

    public final class Coordinator {
        public var player: AVPlayer?
        public var token: Any?
        public var rateObserver: NSKeyValueObservation?
        public var onPlayback: (Bool) -> Void = { _ in }
        public var onTime: (Double) -> Void = { _ in }

        public func observe(_ player: AVPlayer, onTime: @escaping (Double) -> Void, onPlayback: @escaping (Bool) -> Void) {
            self.onPlayback = onPlayback
            if self.player !== player {
                stopObserving()
                self.player = player
                token = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 1 / 30, preferredTimescale: 600),
                    queue: .main
                ) { [weak self, weak player] time in
                    guard let player, self?.player === player else { return }
                    self?.onTime(time.seconds)
                }
                rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] observedPlayer, _ in
                    DispatchQueue.main.async { [weak self] in
                        guard self?.player === observedPlayer else { return }
                        self?.onPlayback(observedPlayer.rate != 0)
                    }
                }
            }
            self.onTime = onTime
            self.onPlayback = onPlayback
        }

        public func stopObserving() {
            if let token { player?.removeTimeObserver(token) }
            rateObserver = nil
            self.token = nil
            player = nil
            onTime = { _ in }
            onPlayback = { _ in }
        }

        deinit {
            stopObserving()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = hiddenControls ? .none : .inline
        view.player = player
        context.coordinator.observe(player, onTime: onTime, onPlayback: onPlayback)
        return view
    }

    public func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let style: AVPlayerViewControlsStyle = hiddenControls ? .none : .inline
        if view.controlsStyle != style { view.controlsStyle = style }
        context.coordinator.observe(player, onTime: onTime, onPlayback: onPlayback)
    }

    public static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.player = nil
    }
}

public struct AudioWaveformView: View {
    public var peaks: [Float]
    public var duration: Double
    public var current: Double
    public var selection: TimeRange?
    public var redactions: [TimeRange]
    public var rangeEnabled: Bool
    public var onSeek: (Double) -> Void
    public var onRange: (Double, Double) -> Void
    @State private var dragging: TimeRange?

    public init(
        peaks: [Float],
        duration: Double,
        current: Double,
        selection: TimeRange? = nil,
        redactions: [TimeRange] = [],
        rangeEnabled: Bool = false,
        onSeek: @escaping (Double) -> Void,
        onRange: @escaping (Double, Double) -> Void
    ) {
        self.peaks = peaks
        self.duration = duration
        self.current = current
        self.selection = selection
        self.redactions = redactions
        self.rangeEnabled = rangeEnabled
        self.onSeek = onSeek
        self.onRange = onRange
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let w = size.width / CGFloat(max(1, peaks.count))
                for (i, p) in peaks.enumerated() {
                    let h = max(1, CGFloat(sqrt(abs(p))) * (size.height - 12))
                    let rect = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w * 0.8), height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(
                            CGFloat(i) * w <= size.width * current / max(0.01, duration)
                                ? ThemeTokenPalette.primaryAccent : .secondary.opacity(0.5)
                        )
                    )
                }
                for range in redactions + [selection, dragging].compactMap({ $0 }) {
                    let rect = CGRect(
                        x: size.width * range.start / max(duration, 0.01),
                        y: 0,
                        width: size.width * (range.end - range.start) / max(duration, 0.01),
                        height: size.height
                    )
                    context.fill(Path(rect), with: .color(ThemeTokenPalette.primaryAccent.opacity(0.18)))
                    context.stroke(Path(rect), with: .color(ThemeTokenPalette.primaryAccent), lineWidth: 1)
                }
                let x = size.width * current / max(duration, 0.01)
                var cursor = Path()
                cursor.move(to: CGPoint(x: x, y: 0))
                cursor.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(cursor, with: .color(.primary), lineWidth: 1)
            }
            .background(Color.primary.opacity(0.035))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let a = max(0, min(duration, value.startLocation.x / geometry.size.width * duration))
                        let b = max(0, min(duration, value.location.x / geometry.size.width * duration))
                        if rangeEnabled {
                            dragging = TimeRange(start: min(a, b), end: max(a, b))
                        } else {
                            onSeek(b)
                        }
                    }
                    .onEnded { value in
                        if let range = dragging, range.end - range.start > 0.01 {
                            onRange(range.start, range.end)
                        } else {
                            onSeek(max(0, min(duration, value.location.x / geometry.size.width * duration)))
                        }
                        dragging = nil
                    }
            )
        }
    }
}

