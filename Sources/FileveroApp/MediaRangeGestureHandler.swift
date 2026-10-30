import AppKit
import FileveroCore
import SwiftUI

// MARK: - MediaRangeGestureHandler: Stationary Lane Pointer & Accessibility Tracking

public struct MediaRangeDrag {
    public enum Target: Equatable {
        case start(Int)
        case end(Int)
        case move(Int)
        case seek, add
    }
    public enum Change: Equatable {
        case range(Int, TimeRange)
        case seek(Double)
        case addition(TimeRange)
    }
    public let target: Target
    public let origin: Double
    public let duration: Double
    public let secondsPerPoint: Double
    public let initial: TimeRange?

    public static func begin(x: Double, duration: Double, width: Double, ranges: [TimeRange], allowsAdding: Bool) -> Self? {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0, x.isFinite else { return nil }
        let secondsPerPoint = duration / width
        var target: Target = allowsAdding ? .add : .seek
        var initial: TimeRange?
        for (index, range) in ranges.enumerated().reversed() where range.start.isFinite && range.end.isFinite {
            let left = range.start / secondsPerPoint
            let right = left + max(14, (range.end - range.start) / secondsPerPoint)
            let startCenter = left + 6
            let endCenter = right - 6
            let startHit = abs(x - startCenter) <= 10
            let endHit = abs(x - endCenter) <= 10
            if startHit || endHit {
                target =
                    startHit && (!endHit || abs(x - startCenter) <= abs(x - endCenter)) ? .start(index) : .end(index)
            } else if x >= left && x <= right {
                target = .move(index)
            } else {
                continue
            }
            initial = TimeRange(start: max(0, min(duration, range.start)), end: max(0, min(duration, range.end)))
            break
        }
        return Self(target: target, origin: x, duration: duration, secondsPerPoint: secondsPerPoint, initial: initial)
    }

    public func change(at x: Double) -> Change {
        let x = x.isFinite ? x : origin
        let delta = (x - origin) * secondsPerPoint
        let minimum = min(0.02, duration)
        func time(_ point: Double) -> Double { max(0, min(duration, point * secondsPerPoint)) }
        switch target {
        case .start(let index):
            let range = initial!
            return .range(
                index, TimeRange(start: max(0, min(range.end - minimum, range.start + delta)), end: range.end))
        case .end(let index):
            let range = initial!
            return .range(
                index, TimeRange(start: range.start, end: min(duration, max(range.start + minimum, range.end + delta))))
        case .move(let index):
            let range = initial!
            let length = max(0, range.end - range.start)
            let start = max(0, min(duration - length, range.start + delta))
            return .range(index, TimeRange(start: start, end: start + length))
        case .seek:
            return .seek(time(x))
        case .add:
            return .addition(TimeRange(start: min(time(origin), time(x)), end: max(time(origin), time(x))))
        }
    }
}

public struct MediaRangeGestureHandler: NSViewRepresentable {
    public let duration: Double
    public let ranges: [TimeRange]
    public let label: String
    public let onSeek: (Double) -> Void
    public let onChange: (Int, TimeRange) -> Void
    public let onPending: (TimeRange?) -> Void
    public var onAdd: ((TimeRange) -> Void)?

    public init(
        duration: Double,
        ranges: [TimeRange],
        label: String,
        onSeek: @escaping (Double) -> Void,
        onChange: @escaping (Int, TimeRange) -> Void,
        onPending: @escaping (TimeRange?) -> Void,
        onAdd: ((TimeRange) -> Void)? = nil
    ) {
        self.duration = duration
        self.ranges = ranges
        self.label = label
        self.onSeek = onSeek
        self.onChange = onChange
        self.onPending = onPending
        self.onAdd = onAdd
    }

    public func makeNSView(context: Context) -> LaneView {
        let view = LaneView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityHelp(L10n.text("Drag either edge to resize the range, or drag its middle to move it."))
        view.setAccessibilityIdentifier("media.range.timeline")
        return view
    }

    public func updateNSView(_ view: LaneView, context: Context) {
        let changed = view.ranges != ranges || view.duration != duration
        view.duration = duration
        view.ranges = ranges
        view.onSeek = onSeek
        view.onChange = onChange
        view.onPending = onPending
        view.onAdd = onAdd
        view.editingEnabled = context.environment.isEnabled
        view.refreshAccessibility()
        view.setAccessibilityLabel(L10n.text("\(L10n.text(label.isEmpty ? "Media range" : label)) timeline"))
        if changed { view.window?.invalidateCursorRects(for: view) }
    }

    public static func dismantleNSView(_ view: LaneView, coordinator: ()) {
        view.cancel()
        view.onSeek = nil
        view.onChange = nil
        view.onPending = nil
        view.onAdd = nil
    }

    public final class LaneView: NSView {
        public var duration = 0.0
        public var ranges: [TimeRange] = []
        public var onSeek: ((Double) -> Void)?
        public var onChange: ((Int, TimeRange) -> Void)?
        public var onPending: ((TimeRange?) -> Void)?
        public var onAdd: ((TimeRange) -> Void)?
        private var drag: MediaRangeDrag?
        public var editingEnabled = true
        private var endpointElements: [RangeEndpointAccessibilityElement] = []
        private var observedValues: [String: Double] = [:]

        public func refreshAccessibility() {
            let indices = ranges.indices.filter { isEditableRange($0) }
            let keys = indices.flatMap { index in ["media.range.\(index).start", "media.range.\(index).end"] }
            if endpointElements.map({ $0.identifier }) != keys {
                let previous = Dictionary(uniqueKeysWithValues: endpointElements.map { ($0.identifier, $0) })
                endpointElements = indices.flatMap { index in
                    [true, false].map { start in
                        let id = "media.range.\(index).\(start ? "start" : "end")"
                        return previous[id] ?? RangeEndpointAccessibilityElement(lane: self, index: index, start: start)
                    }
                }
                setAccessibilityChildren(endpointElements)
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
            for element in endpointElements {
                let value = element.value
                if let previous = observedValues[element.identifier], previous != value {
                    NSAccessibility.post(element: element, notification: .valueChanged)
                }
                observedValues[element.identifier] = value
            }
            observedValues = observedValues.filter { keys.contains($0.key) }
        }

        public func isEditableRange(_ index: Int) -> Bool {
            guard duration.isFinite, duration > 0, ranges.indices.contains(index) else { return false }
            let range = ranges[index]
            return range.start.isFinite && range.end.isFinite && range.start >= 0 && range.end <= duration
                && range.end > range.start
        }

        public func canEditRange(_ index: Int) -> Bool {
            editingEnabled && onChange != nil && isEditableRange(index)
        }

        public func endpointBounds(index: Int, start: Bool) -> ClosedRange<Double>? {
            guard isEditableRange(index) else { return nil }
            let range = ranges[index]
            let minimum = min(0.02, duration)
            return start ? 0...max(0, range.end - minimum) : min(duration, range.start + minimum)...duration
        }

        @discardableResult
        public func setEndpoint(index: Int, start: Bool, value: Double) -> Bool {
            guard canEditRange(index), value.isFinite, let limits = endpointBounds(index: index, start: start) else {
                return false
            }
            let bounded = max(limits.lowerBound, min(limits.upperBound, value))
            let old = ranges[index]
            let next = start ? TimeRange(start: bounded, end: old.end) : TimeRange(start: old.start, end: bounded)
            guard next != old else { return false }
            ranges[index] = next
            onChange?(index, next)
            refreshAccessibility()
            return true
        }

        public func endpointFrame(index: Int, start: Bool) -> NSRect {
            guard isEditableRange(index), let window else { return .zero }
            let range = ranges[index]
            let left = range.start / duration * Double(bounds.width)
            let width = max(14, (range.end - range.start) / duration * Double(bounds.width))
            let center = start ? left + 6 : left + width - 6
            let rect = NSRect(x: center - 10, y: 0, width: 20, height: bounds.height).intersection(bounds)
            guard !rect.isEmpty else { return .zero }
            return window.convertToScreen(convert(rect, to: nil))
        }

        public override var isFlipped: Bool { true }
        public override var acceptsFirstResponder: Bool { true }
        public override var mouseDownCanMoveWindow: Bool { false }
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            drag = MediaRangeDrag.begin(
                x: Double(convert(event.locationInWindow, from: nil).x),
                duration: duration,
                width: Double(bounds.width),
                ranges: ranges,
                allowsAdding: onAdd != nil)
            update(event, ending: false)
        }

        public override func mouseDragged(with event: NSEvent) {
            update(event, ending: false)
        }

        public override func mouseUp(with event: NSEvent) {
            update(event, ending: true)
            cancel()
        }

        public override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { cancel() }
            super.viewWillMove(toWindow: newWindow)
        }

        public func cancel() {
            drag = nil
            onPending?(nil)
        }

        private func update(_ event: NSEvent, ending: Bool) {
            guard let drag else { return }
            switch drag.change(at: Double(convert(event.locationInWindow, from: nil).x)) {
            case .range(let index, let range):
                if ranges.indices.contains(index) { onChange?(index, range) }
            case .seek(let time):
                onSeek?(time)
            case .addition(let range):
                if ending {
                    if range.end - range.start > 0.01 { onAdd?(range) } else { onSeek?(range.end) }
                } else {
                    onPending?(range)
                }
            }
        }

        public override func resetCursorRects() {
            super.resetCursorRects()
            guard duration.isFinite, duration > 0, bounds.width > 0 else { return }
            if onAdd != nil { addCursorRect(bounds, cursor: .crosshair) }
            for range in ranges where range.start.isFinite && range.end.isFinite {
                let left = range.start / duration * Double(bounds.width)
                let width = max(14, (range.end - range.start) / duration * Double(bounds.width))
                let body = NSRect(x: left, y: 0, width: width, height: bounds.height).intersection(bounds)
                if !body.isEmpty { addCursorRect(body, cursor: .openHand) }
                for x in [left - 4, left + width - 16] {
                    let handle = NSRect(x: x, y: 0, width: 20, height: bounds.height).intersection(bounds)
                    if !handle.isEmpty { addCursorRect(handle, cursor: .resizeLeftRight) }
                }
            }
        }
    }
}

@MainActor public final class RangeEndpointAccessibilityElement: NSAccessibilityElement {
    public weak var lane: MediaRangeGestureHandler.LaneView?
    public let index: Int
    public let start: Bool
    public let identifier: String

    public init(lane: MediaRangeGestureHandler.LaneView, index: Int, start: Bool) {
        self.lane = lane
        self.index = index
        self.start = start
        identifier = "media.range.\(index).\(start ? "start" : "end")"
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityParent(lane)
        setAccessibilityIdentifier(identifier)
    }

    public var value: Double {
        guard let lane, lane.isEditableRange(index) else { return 0 }
        return start ? lane.ranges[index].start : lane.ranges[index].end
    }

    public override func accessibilityLabel() -> String? {
        let label = L10n.text(start ? "Start" : "End")
        return (lane?.ranges.count ?? 0) > 1 ? "\(label) \(index + 1)" : label
    }

    public override func accessibilityHelp() -> String? { L10n.text("Seconds") }
    public override func accessibilityValue() -> Any? { NSNumber(value: value) }
    public override func accessibilityValueDescription() -> String? {
        String(format: "%.3f", value) + " " + L10n.text("Seconds")
    }

    public override func accessibilityMinValue() -> Any? {
        NSNumber(value: lane?.endpointBounds(index: index, start: start)?.lowerBound ?? 0)
    }

    public override func accessibilityMaxValue() -> Any? {
        NSNumber(value: lane?.endpointBounds(index: index, start: start)?.upperBound ?? 0)
    }

    public override func accessibilityFrame() -> NSRect {
        lane?.endpointFrame(index: index, start: start) ?? .zero
    }

    public override func isAccessibilityEnabled() -> Bool {
        lane?.canEditRange(index) ?? false
    }

    public override func setAccessibilityValue(_ value: Any?) {
        let number =
            (value as? NSNumber)?.doubleValue
            ?? (value as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        if let number { lane?.setEndpoint(index: index, start: start, value: number) }
    }

    public override func accessibilityPerformIncrement() -> Bool {
        lane?.setEndpoint(index: index, start: start, value: value + 0.1) ?? false
    }

    public override func accessibilityPerformDecrement() -> Bool {
        lane?.setEndpoint(index: index, start: start, value: value - 0.1) ?? false
    }

    public override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector) == "setAccessibilityValue:" { return isAccessibilityEnabled() }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

// MARK: - Compatibility Bridge
public typealias MediaRangeInteraction = MediaRangeGestureHandler

