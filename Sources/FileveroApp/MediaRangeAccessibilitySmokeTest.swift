import AppKit
import FileveroCore
import SwiftUI

/// In-process regression test for the timeline component and its native accessibility actions.
/// Never reads user files, posts global input, or requests TCC permissions.
@MainActor
public final class MediaRangeAccessibilitySmokeTest: NSObject, NSApplicationDelegate {
    private let outputDirectory: URL
    private var window: NSWindow?
    private var checksPassed: [String] = []
    private let keepOpen: Bool

    public init(output: URL, keepOpen: Bool = CommandLine.arguments.contains("--keep-range-open")) {
        self.outputDirectory = output
        self.keepOpen = keepOpen
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            var failureMessage: String?
            do {
                try await executeAccessibilityVerification()
            } catch {
                failureMessage = String(describing: error)
            }

            let resultRecord: [String: Any] = [
                "passed": failureMessage == nil,
                "checks": checksPassed,
                "error": failureMessage as Any? ?? NSNull(),
                "scope": "Production timeline accessibility, slider semantics, boundary conditions, and direct pointer dragging."
            ]

            if let serialized = try? JSONSerialization.data(withJSONObject: resultRecord, options: [.prettyPrinted, .sortedKeys]) {
                try? serialized.write(to: outputDirectory.appendingPathComponent("mac-range-accessibility.json"))
            }

            if failureMessage == nil && keepOpen {
                window?.title = "Filevero Range Accessibility QA — Passed"
                return
            }

            window?.close()
            exit(failureMessage == nil ? 0 : 1)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func verify(_ condition: Bool, _ label: String) throws {
        guard condition else {
            throw NSError(
                domain: "Filevero Range Accessibility QA",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: label]
            )
        }
        checksPassed.append(label)
    }

    private func isNear(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.000_001
    }

    private func yieldTurn() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func findLaneView(in view: NSView) -> MediaRangeGestureHandler.LaneView? {
        if let lane = view as? MediaRangeGestureHandler.LaneView { return lane }
        return view.subviews.lazy.compactMap { self.findLaneView(in: $0) }.first
    }

    private func captureScreenshot() throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: outputDirectory.appendingPathComponent("mac-range-accessibility.png"))
        }
    }

    private func simulatePointerDrag(_ lane: MediaRangeGestureHandler.LaneView, from startX: Double, to endX: Double) throws {
        guard let window = lane.window else {
            throw NSError(domain: "Filevero Range Accessibility QA", code: 2)
        }
        func makeMouseEvent(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: lane.convert(NSPoint(x: x, y: lane.bounds.midY), to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        lane.mouseDown(with: makeMouseEvent(.leftMouseDown, startX))
        lane.mouseDragged(with: makeMouseEvent(.leftMouseDragged, endX))
        lane.mouseUp(with: makeMouseEvent(.leftMouseUp, endX))
    }

    private func executeAccessibilityVerification() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fixture = RangeModelFixture()
        let testWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 100, width: 448, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        testWindow.title = "Filevero Range Accessibility QA"
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = NSHostingView(rootView: RangeFixturePresentationView(fixture: fixture).preferredColorScheme(.dark))
        window = testWindow
        testWindow.makeKeyAndOrderFront(nil)

        await yieldTurn()
        await yieldTurn()

        guard let content = testWindow.contentView, let lane = findLaneView(in: content) else {
            throw NSError(
                domain: "Filevero Range Accessibility QA",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Production timeline did not mount"]
            )
        }

        func retrieveEndpoints() -> [RangeEndpointAccessibilityElement] {
            lane.accessibilityChildren() as? [RangeEndpointAccessibilityElement] ?? []
        }

        let initialEndpoints = retrieveEndpoints()
        try verify(
            lane.accessibilityIdentifier() == "media.range.timeline" && lane.accessibilityRole() == .group,
            "Production timeline exposes a stable semantic group"
        )
        try verify(initialEndpoints.count == 2, "One selected range exposes independent start and end controls")

        let startControl = initialEndpoints[0]
        let endControl = initialEndpoints[1]

        try verify(
            startControl.accessibilityIdentifier() == "media.range.0.start" &&
            endControl.accessibilityIdentifier() == "media.range.0.end",
            "Start and end controls have stable accessibility identifiers"
        )
        try verify(
            initialEndpoints.allSatisfy { $0.accessibilityRole() == .slider && $0.isAccessibilityEnabled() },
            "Both endpoints expose enabled native slider roles"
        )
        try verify(
            startControl.accessibilityLabel() == L10n.text("Start") && endControl.accessibilityLabel() == L10n.text("End"),
            "Endpoint names follow the app language"
        )
        try verify(
            !startControl.accessibilityFrame().isEmpty && !endControl.accessibilityFrame().isEmpty,
            "Both endpoint frames identify the painted handles in screen coordinates"
        )
        try verify(
            isNear((startControl.accessibilityMinValue() as? NSNumber)?.doubleValue ?? -1, 0) &&
            isNear((startControl.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1, 7.98),
            "Start exposes the current opposite-edge bound"
        )
        try verify(
            isNear((endControl.accessibilityMinValue() as? NSNumber)?.doubleValue ?? -1, 2.02) &&
            isNear((endControl.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1, 10),
            "End exposes the current opposite-edge bound"
        )

        try verify(startControl.accessibilityPerformIncrement(), "Start supports the native increment action")
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 2.1) && isNear(fixture.ranges[0].end, 8),
            "Increment moves only Start through the production callback"
        )

        try verify(endControl.accessibilityPerformDecrement(), "End supports the native decrement action")
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 2.1) && isNear(fixture.ranges[0].end, 7.9),
            "Decrement moves only End through the production callback"
        )

        try verify(
            retrieveEndpoints()[0] === startControl && retrieveEndpoints()[1] === endControl,
            "Value updates preserve endpoint identity and assistive focus"
        )

        startControl.setAccessibilityValue(NSNumber(value: 9))
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 7.88) && isNear(fixture.ranges[0].end, 7.9),
            "Setting Start beyond End clamps to the minimum span without moving End"
        )

        startControl.setAccessibilityValue(NSNumber(value: -100))
        await yieldTurn()
        try verify(isNear(fixture.ranges[0].start, 0), "Start cannot move before the source")

        let changesBeforeBoundary = fixture.changeCount
        try verify(
            !startControl.accessibilityPerformDecrement() && fixture.changeCount == changesBeforeBoundary,
            "A boundary action is a no-op without a duplicate callback"
        )

        endControl.setAccessibilityValue(NSNumber(value: -1))
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].end, 0.02) && isNear(fixture.ranges[0].start, 0),
            "End cannot cross Start or collapse the selected range"
        )

        endControl.setAccessibilityValue(NSNumber(value: 100))
        await yieldTurn()
        try verify(isNear(fixture.ranges[0].end, 10), "End cannot move beyond the source duration")

        startControl.setAccessibilityValue("6,250")
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 6.25) && isNear(fixture.ranges[0].end, 10),
            "A numeric accessibility value uses the same bounded callback"
        )

        let changesBeforeInvalid = fixture.changeCount
        startControl.setAccessibilityValue(NSNumber(value: Double.nan))
        endControl.setAccessibilityValue(NSNumber(value: Double.infinity))
        startControl.setAccessibilityValue("invalid")
        try verify(fixture.changeCount == changesBeforeInvalid, "Non-finite and invalid accessibility values are ignored")

        fixture.enabled = false
        await yieldTurn()
        let changesBeforeDisabled = fixture.changeCount
        startControl.setAccessibilityValue(NSNumber(value: 1))
        try verify(
            !startControl.isAccessibilityEnabled() && !startControl.accessibilityPerformIncrement() &&
            fixture.changeCount == changesBeforeDisabled,
            "Disabled timelines block both set and adjustment actions"
        )
        try verify(
            !startControl.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")),
            "Disabled endpoints advertise a read-only accessibility value"
        )

        fixture.enabled = true
        fixture.ranges = [TimeRange(start: 1, end: 3), TimeRange(start: 6, end: 9)]
        await yieldTurn()

        let multiEndpoints = retrieveEndpoints()
        try verify(
            multiEndpoints.count == 4 &&
            multiEndpoints[2].accessibilityIdentifier() == "media.range.1.start" &&
            multiEndpoints[3].accessibilityIdentifier() == "media.range.1.end",
            "Multiple ranges expose separately identified endpoints"
        )
        try verify(multiEndpoints[2].accessibilityPerformIncrement(), "A later range can be adjusted independently")
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[1].start, 6.1) && fixture.ranges[0] == TimeRange(start: 1, end: 3),
            "Adjusting a later range leaves the first range unchanged"
        )

        let detachedEndpoint = multiEndpoints[3]
        fixture.ranges = [TimeRange(start: 2, end: 8)]
        await yieldTurn()
        try verify(
            retrieveEndpoints().count == 2 && !detachedEndpoint.accessibilityPerformIncrement(),
            "Removed endpoints are detached and stale actions are safe"
        )

        fixture.duration = 0
        await yieldTurn()
        try verify(
            retrieveEndpoints().isEmpty && !startControl.accessibilityPerformIncrement(),
            "An unavailable duration exposes no editable endpoints"
        )

        fixture.duration = 0.01
        fixture.ranges = [TimeRange(start: 0, end: 0.01)]
        await yieldTurn()
        let tinyEndpoints = retrieveEndpoints()
        try verify(
            tinyEndpoints.count == 2 && !tinyEndpoints[0].accessibilityPerformIncrement() && !tinyEndpoints[1].accessibilityPerformDecrement(),
            "Sub-frame sources keep valid independent bounds"
        )

        fixture.duration = 10
        fixture.ranges = [TimeRange(start: 2, end: 8)]
        await yieldTurn()

        let totalWidth = Double(lane.bounds.width)
        try simulatePointerDrag(lane, from: totalWidth * 0.8 - 6, to: totalWidth * 0.9 - 6)
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 2) && isNear(fixture.ranges[0].end, 9),
            "Existing native pointer drag still resizes End without rebasing"
        )

        fixture.ranges = [TimeRange(start: 2, end: 8)]
        await yieldTurn()
        try simulatePointerDrag(lane, from: totalWidth * 0.4, to: totalWidth * 0.5)
        await yieldTurn()
        try verify(
            isNear(fixture.ranges[0].start, 3) && isNear(fixture.ranges[0].end, 9),
            "Existing native pointer drag still moves the full range"
        )

        fixture.ranges = [TimeRange(start: 2, end: 8)]
        await yieldTurn()
        try captureScreenshot()
    }
}

// MARK: - Fixture Support
@MainActor
private final class RangeModelFixture: ObservableObject {
    @Published var duration: Double = 10.0
    @Published var ranges: [TimeRange] = [TimeRange(start: 2, end: 8)]
    @Published var enabled: Bool = true
    private(set) var changeCount: Int = 0

    func change(_ index: Int, _ range: TimeRange) {
        guard ranges.indices.contains(index) else { return }
        ranges[index] = range
        changeCount += 1
    }
}

private struct RangeFixturePresentationView: View {
    @ObservedObject var fixture: RangeModelFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Trim · semantic Start and End")
                .font(.headline)
            MediaTimeRangeLane(
                duration: fixture.duration,
                current: 0,
                ranges: fixture.ranges,
                label: "Trim",
                onSeek: { _ in },
                onChange: fixture.change
            )
            .disabled(!fixture.enabled)

            Text(String(format: "%.3f – %.3f seconds", fixture.ranges.first?.start ?? 0, fixture.ranges.first?.end ?? 0))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 448, height: 180)
    }
}

// MARK: - Backwards Compatibility Bridge
public typealias MediaRangeAccessibilitySmoke = MediaRangeAccessibilitySmokeTest

