import AppKit

/// Runs a drag-tracking `tick` at 40 Hz only while the left mouse button is held, and stays idle
/// otherwise. A press anywhere (seen through global and local event monitors) resumes polling;
/// polling stops once the button has stayed up for a short grace period.
@MainActor
final class LeftMouseHoldPoller {
    private static let interval: TimeInterval = 0.025
    // Button-state reads can briefly report "up" during another app's drag; keep polling through them.
    private static let releaseGrace: TimeInterval = 0.3

    private let onIdlePress: () -> Void
    private let tick: () -> Void
    private var timer: Timer?
    private var monitors: [Any] = []
    private var releasedSince: TimeInterval?

    /// `onIdlePress` runs before the first tick of a press that arrives while polling was idle,
    /// so owners can record the state they would otherwise have observed while the button was up.
    init(onIdlePress: @escaping () -> Void, tick: @escaping () -> Void) {
        self.onIdlePress = onIdlePress
        self.tick = tick
    }

    static var isLeftButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 || CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.received(event.type) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.received(event.type) }
            return event
        }) {
            monitors.append(local)
        }
        // Covers a button already held at launch; with the button up this idles after the grace period.
        resume()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        timer?.invalidate()
        timer = nil
        releasedSince = nil
    }

    private func received(_ type: NSEvent.EventType) {
        if type == .leftMouseDown, timer == nil { onIdlePress() }
        resume()
    }

    private func resume() {
        releasedSince = nil
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        tick()
        guard !Self.isLeftButtonDown else {
            releasedSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = releasedSince else {
            releasedSince = now
            return
        }
        if now - since >= Self.releaseGrace {
            timer?.invalidate()
            timer = nil
            releasedSince = nil
        }
    }
}
