import AppKit
import ApplicationServices
import FileveroCore

// MARK: - AppWindowManager & WindowPlacementGlyph: Native Window Management & Wheel Tiling

public enum WindowPlacementGlyph {
    public static func draw(_ placement: WindowPlacement, in slot: NSRect, color: NSColor) {
        let rect = NSRect(x: slot.midX - 12, y: slot.midY - 8, width: 24, height: 16)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        color.setStroke()
        outline.lineWidth = 1.3
        outline.stroke()
        let range = placement.horizontalRange
        let vertical = placement.verticalRange
        color.withAlphaComponent(0.7).setFill()
        NSBezierPath(
            rect: NSRect(
                x: rect.minX + 2 + (rect.width - 4) * range.lowerBound,
                y: rect.minY + 2 + (rect.height - 4) * vertical.lowerBound,
                width: (rect.width - 4) * (range.upperBound - range.lowerBound),
                height: (rect.height - 4) * (vertical.upperBound - vertical.lowerBound))
        ).fill()
    }
}

@MainActor public final class AppWindowManager {
    private struct Target {
        let element: AXUIElement
        let pid: pid_t
        let initialFrame: CGRect
        let origin: NSPoint
        var latestFrame: CGRect
        var intent = WindowDragIntent()
    }

    // AXUIElement references may be messaged from any thread.
    private struct CapturedWindow: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let frame: CGRect
    }

    private var poller: LeftMouseHoldPoller?
    // AX calls block until the target app answers (or times out), so they run off the main actor.
    private var captureTask: Task<Void, Never>?
    private var frameProbe: Task<Void, Never>?
    private var target: Target?
    private var wasDown = false
    private var fileSession = DragPasteboardSession()
    private var wheelPanel: NSPanel?
    private var wheel: WheelView?
    private var preview: NSPanel?
    private var lastPreview: String?
    private var qaCaptureAttempted = false
    private var accessibilityTrusted = false
    private var nextAccessibilityCheck: TimeInterval = 0
    private var placementTask: Task<Void, Never>?
    private var restoreFrames: [(element: AXUIElement, frame: CGRect)] = []
    private static let restoreHistoryLimit = 30
    private let fileWheelIsVisible: () -> Bool
    public var onNotice: ((String) -> Void)?

    public init(fileWheelIsVisible: @escaping () -> Bool) {
        self.fileWheelIsVisible = fileWheelIsVisible
        let poller = LeftMouseHoldPoller(
            onIdlePress: { [weak self] in
                self?.fileSession.observeIdle(changeCount: NSPasteboard(name: .drag).changeCount)
            },
            tick: { [weak self] in self?.tick() })
        self.poller = poller
        poller.start()
    }

    public func stop() {
        placementTask?.cancel()
        poller?.stop()
        poller = nil
        cancel()
        resetTarget()
    }

    private func resetTarget() {
        captureTask?.cancel()
        captureTask = nil
        frameProbe?.cancel()
        frameProbe = nil
        target = nil
    }

    public static var permissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access" : "Accessibility"
    }

    public static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        let down =
            NSEvent.pressedMouseButtons & 1 != 0 || CGEventSource.buttonState(.combinedSessionState, button: .left)
        let freshFile = fileSession.containsFreshDrag(
            isDown: down,
            changeCount: NSPasteboard(name: .drag).changeCount,
            now: ProcessInfo.processInfo.systemUptime)
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextAccessibilityCheck {
            accessibilityTrusted = AXIsProcessTrusted()
            nextAccessibilityCheck = now + 1
        }
        defer { wasDown = down }
        guard UserDefaults.standard.bool(forKey: "enabled"),
            UserDefaults.standard.bool(forKey: "windowManagementEnabled"), accessibilityTrusted
        else {
            placementTask?.cancel()
            cancel()
            resetTarget()
            return
        }
        if !down {
            if wasDown, let captured = target, let item = currentItem(at: point),
                !captured.intent.cancelled, !freshFile
            {
                let screen = screen(at: point)
                cancel()
                resetTarget()
                placementTask?.cancel()
                placementTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if let placement = item.windowPlacement {
                        self.rememberFrame(of: captured)
                        await self.apply(placement, to: captured.element, pid: captured.pid, on: screen)
                    } else if let command = item.windowCommand,
                        let frame = self.frame(for: command, window: captured.element, current: captured.latestFrame)
                    {
                        if command == .nextDisplay { self.rememberFrame(of: captured) }
                        if await self.move(captured.element, pid: captured.pid, to: frame), command == .restore {
                            self.forgetFrame(of: captured.element)
                        }
                    }
                }
            } else {
                cancel()
                resetTarget()
            }
            return
        }
        if !wasDown {
            placementTask?.cancel()
            beginCapture(at: point)
        }
        guard var candidate = target else { return }
        if CGEventSource.keyState(.combinedSessionState, key: 53) {
            candidate.intent.cancel()
            target = candidate
            cancel()
            return
        }
        if freshFile || fileWheelIsVisible() {
            candidate.intent.cancel()
            target = candidate
            cancel()
            return
        }
        refreshFrame(of: candidate.element)
        let frame = candidate.latestFrame
        let flags = NSEvent.modifierFlags.union(
            NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)))
        let changed =
            abs(frame.minX - candidate.initialFrame.minX) > 2 || abs(frame.minY - candidate.initialFrame.minY) > 2
            || abs(frame.width - candidate.initialFrame.width) > 2
            || abs(frame.height - candidate.initialFrame.height) > 2
        let accepts = candidate.intent.accepts(
            pointerDistance: hypot(point.x - candidate.origin.x, point.y - candidate.origin.y),
            frameChanged: changed,
            freshFileDrag: freshFile,
            requested: !flags.intersection([.shift, .command]).isEmpty)
        target = candidate
        if accepts, wheelPanel?.isVisible != true { show(at: point, for: candidate.element) }
        guard wheelPanel?.isVisible == true, let wheel, let panel = wheelPanel else { return }
        wheel.updateSelection(wheel.convert(panel.convertPoint(fromScreen: point), from: nil))
        updatePreview(currentItem(at: point), target: candidate, on: screen(at: point))
        captureOwnWheelForQA()
    }

    private func captureOwnWheelForQA() {
        guard !qaCaptureAttempted, wheel?.selected != nil,
            let index = CommandLine.arguments.firstIndex(of: "--capture-window-wheel"),
            index + 1 < CommandLine.arguments.count,
            let view = wheelPanel?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        qaCaptureAttempted = true
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("mac-window-wheel-view.png"), options: .atomic)
        } catch {
            fputs("Filevero window QA view capture failed.\n", stderr)
        }
    }

    private func beginCapture(at point: NSPoint) {
        resetTarget()
        let axPoint = Self.accessibilityPoint(point)
        captureTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.captureWindow(at: axPoint) }.value
            guard !Task.isCancelled, let self, let found else { return }
            self.captureTask = nil
            self.target = Target(
                element: found.element, pid: found.pid, initialFrame: found.frame, origin: point,
                latestFrame: found.frame)
        }
    }

    /// Reads the dragged window's frame in the background; ticks use the latest result.
    private func refreshFrame(of element: AXUIElement) {
        guard frameProbe == nil else { return }
        let window = CapturedWindow(element: element, pid: 0, frame: .zero)
        frameProbe = Task { [weak self] in
            let frame = await Task.detached(priority: .userInitiated) { Self.frame(of: window.element) }.value
            guard !Task.isCancelled, let self else { return }
            self.frameProbe = nil
            guard var current = self.target, CFEqual(current.element, element) else { return }
            guard let frame else {
                self.cancel()
                self.resetTarget()
                return
            }
            current.latestFrame = frame
            self.target = current
        }
    }

    private nonisolated static func captureWindow(at axPoint: CGPoint) -> CapturedWindow? {
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
            let hit
        else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.075)
        let role = attribute(hit, kAXRoleAttribute) as? String
        guard ![kAXTextFieldRole, kAXTextAreaRole, kAXScrollBarRole, "AXSecureTextField"].contains(role ?? "") else {
            return nil
        }
        var element: AXUIElement?
        if role == kAXWindowRole {
            element = hit
        } else if let window = attribute(hit, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            element = (window as! AXUIElement)
        }
        guard let window = element else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.075)
        guard let frame = frame(of: window) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, isUsable(window, pid: pid) else { return nil }
        let inTop = axPoint.y >= frame.minY - 5 && axPoint.y <= frame.minY + 88
        let edge =
            min(
                abs(axPoint.x - frame.minX), abs(axPoint.x - frame.maxX), abs(axPoint.y - frame.minY),
                abs(axPoint.y - frame.maxY)) <= 9
        guard inTop || edge else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.075)
        return CapturedWindow(element: window, pid: pid, frame: frame)
    }

    private func paletteItems(for window: AXUIElement) -> [WheelItem] {
        var items = WindowPlacement.allCases.map {
            WheelItem(title: $0.title, symbol: "rectangle", windowPlacement: $0)
        }
        let commands = WindowCommand.allCases.filter {
            $0 == .restore ? savedFrame(of: window) != nil : NSScreen.screens.count > 1
        }
        items += commands.map { WheelItem(title: $0.title, symbol: $0.symbol, windowCommand: $0) }
        return items
    }

    private func show(at point: NSPoint, for window: AXUIElement) {
        WheelFeedback.shared.prepare()
        if wheelPanel == nil {
            let size = CGFloat(320 * UserDefaults.standard.double(forKey: "wheelScale"))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Filevero Window Management"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = size / 2
            effect.layer?.masksToBounds = true
            let view = WheelView(frame: effect.bounds)
            view.autoresizingMask = [.width, .height]
            view.centerTitle = "Arrange window"
            view.mode = .tools
            view.onCancel = { [weak self] in
                self?.cancel()
                self?.target?.intent.cancel()
            }
            effect.addSubview(view)
            panel.contentView = effect
            wheelPanel = panel
            wheel = view
        }
        guard let panel = wheelPanel else { return }
        wheel?.items = paletteItems(for: window)
        let area = screen(at: point).visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: min(max(area.minX + 4, point.x - panel.frame.width / 2), area.maxX - panel.frame.width - 4),
                y: min(max(area.minY + 4, point.y - panel.frame.height / 2), area.maxY - panel.frame.height - 4)))
        wheel?.selected = nil
        wheel?.needsDisplay = true
        wheel?.updateAccessibility()
        panel.orderFrontRegardless()
    }

    private func currentItem(at point: NSPoint) -> WheelItem? {
        guard wheelPanel?.isVisible == true, let panel = wheelPanel, let wheel else { return nil }
        let local = wheel.convert(panel.convertPoint(fromScreen: point), from: nil)
        guard let index = wheel.items.indices.first(where: { wheel.petal($0).contains(local) }) else { return nil }
        return wheel.items[index]
    }

    private func rememberFrame(of target: Target) {
        guard savedFrame(of: target.element) == nil else { return }
        restoreFrames.append((target.element, Self.appKitFrame(target.initialFrame)))
        if restoreFrames.count > Self.restoreHistoryLimit { restoreFrames.removeFirst() }
    }

    private func forgetFrame(of window: AXUIElement) {
        restoreFrames.removeAll { CFEqual($0.element, window) }
    }

    private func savedFrame(of window: AXUIElement) -> CGRect? {
        restoreFrames.last { CFEqual($0.element, window) }?.frame
    }

    /// `current` is the window's latest accessibility frame, read off the main actor by the caller.
    private func frame(for command: WindowCommand, window: AXUIElement, current axFrame: CGRect) -> CGRect? {
        switch command {
        case .restore:
            return savedFrame(of: window).map { WindowGeometry.clamp($0, to: NSScreen.screens.map(\.visibleFrame)) }
        case .nextDisplay:
            let current = Self.appKitFrame(axFrame)
            let displays = NSScreen.screens.map(\.visibleFrame)
            guard let source = WindowGeometry.display(for: current, in: displays),
                let target = WindowGeometry.display(after: source, in: displays)
            else { return nil }
            return WindowGeometry.move(current, from: source, to: target)
        }
    }

    private func updatePreview(_ item: WheelItem?, target: Target, on screen: NSScreen) {
        let frame: CGRect?
        let title: String
        if let placement = item?.windowPlacement {
            frame = placement.frame(in: screen.visibleFrame, scale: screen.backingScaleFactor)
            title = L10n.text(placement.title) + " · " + placement.fraction
        } else if let command = item?.windowCommand {
            frame = self.frame(for: command, window: target.element, current: target.latestFrame)
            title = L10n.text(command.title)
        } else {
            frame = nil
            title = ""
        }
        guard let frame else {
            preview?.orderOut(nil)
            lastPreview = nil
            return
        }
        if preview == nil {
            let overlay = NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            overlay.title = "Filevero Placement Preview"
            overlay.level = .floating
            overlay.ignoresMouseEvents = true
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            overlay.hasShadow = false
            overlay.hidesOnDeactivate = false
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            overlay.contentView = WindowPlacementPreviewView()
            preview = overlay
        }
        if preview?.frame != frame { preview?.setFrame(frame, display: true) }
        if let view = preview?.contentView as? WindowPlacementPreviewView {
            view.title = title
            view.needsDisplay = true
        }
        if lastPreview != title || preview?.isVisible != true { preview?.orderFrontRegardless() }
        lastPreview = title
    }

    private func cancel() {
        wheelPanel?.orderOut(nil)
        wheel?.selected = nil
        preview?.orderOut(nil)
        lastPreview = nil
    }

    private func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func apply(_ placement: WindowPlacement, to window: AXUIElement, pid: pid_t, on screen: NSScreen) async {
        let handle = CapturedWindow(element: window, pid: pid, frame: .zero)
        let primaryMaxY = Self.primaryScreenMaxY
        guard AXIsProcessTrusted(), await Self.offMain({ Self.prepareForArrangement(handle) }) else { return }
        var wanted = placement.frame(in: screen.visibleFrame, scale: screen.backingScaleFactor)
        for attempt in 0..<4 {
            guard !Task.isCancelled else { return }
            let request = wanted
            guard
                let acknowledged = await Self.offMain({
                    Self.isUsable(handle.element, pid: pid)
                        ? Self.requestFrame(request, of: handle.element, primaryMaxY: primaryMaxY) : nil
                })
            else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let actual = await Self.offMain({ Self.frame(of: handle.element) }) else { return }
            let origin = Self.accessibilityPoint(NSPoint(x: wanted.minX, y: wanted.maxY), primaryMaxY: primaryMaxY)
            if abs(actual.width - wanted.width) < 3, abs(actual.height - wanted.height) < 3,
                abs(actual.minX - origin.x) < 3, abs(actual.minY - origin.y) < 3
            {
                return
            }
            if acknowledged, attempt >= 1, actual.width > wanted.width + 3 || actual.height > wanted.height + 3 {
                wanted = placement.frame(
                    in: screen.visibleFrame, scale: screen.backingScaleFactor, minimumSize: actual.size)
            }
        }
        if !Task.isCancelled {
            onNotice?("This window could not be arranged. The app may restrict resizing.")
        }
    }

    private func move(_ window: AXUIElement, pid: pid_t, to frame: CGRect) async -> Bool {
        let handle = CapturedWindow(element: window, pid: pid, frame: .zero)
        let primaryMaxY = Self.primaryScreenMaxY
        guard AXIsProcessTrusted(), await Self.offMain({ Self.prepareForArrangement(handle) }) else { return false }
        for _ in 0..<3 {
            guard !Task.isCancelled,
                await Self.offMain({
                    guard Self.isUsable(handle.element, pid: pid) else { return false }
                    _ = Self.requestFrame(frame, of: handle.element, primaryMaxY: primaryMaxY)
                    return true
                })
            else { return false }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let actual = await Self.offMain({ Self.frame(of: handle.element) })
                .map({ Self.appKitFrame($0, primaryMaxY: primaryMaxY) }),
                abs(actual.minX - frame.minX) < 3,
                abs(actual.minY - frame.minY) < 3, abs(actual.width - frame.width) < 3,
                abs(actual.height - frame.height) < 3
            {
                return true
            }
        }
        if !Task.isCancelled {
            onNotice?("This window could not be arranged. The app may restrict resizing.")
        }
        return false
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private nonisolated static func prepareForArrangement(_ window: CapturedWindow) -> Bool {
        guard isUsable(window.element, pid: window.pid) else { return false }
        AXUIElementSetMessagingTimeout(window.element, 0.5)
        return true
    }

    private static var primaryScreenMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    public static func appKitFrame(_ frame: CGRect) -> CGRect {
        appKitFrame(frame, primaryMaxY: primaryScreenMaxY)
    }

    nonisolated static func appKitFrame(_ frame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryMaxY - frame.maxY,
            width: frame.width,
            height: frame.height)
    }

    public nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    public nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute),
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    public nonisolated static func isUsable(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard pid > 0, NSRunningApplication(processIdentifier: pid)?.isTerminated == false,
            attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
            attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
            attribute(window, kAXMinimizedAttribute) as? Bool != true,
            attribute(window, "AXFullScreen") as? Bool != true
        else { return false }
        var position: DarwinBoolean = false
        var size: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &position) == .success
            && position.boolValue
            && AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &size) == .success && size.boolValue
    }

    public static func accessibilityPoint(_ point: NSPoint) -> CGPoint {
        accessibilityPoint(point, primaryMaxY: primaryScreenMaxY)
    }

    nonisolated static func accessibilityPoint(_ point: NSPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    public static func setFrame(_ frame: NSRect, of window: AXUIElement) -> Bool {
        setFrame(frame, of: window, primaryMaxY: primaryScreenMaxY)
    }

    nonisolated static func setFrame(_ frame: NSRect, of window: AXUIElement, primaryMaxY: CGFloat) -> Bool {
        guard requestFrame(frame, of: window, primaryMaxY: primaryMaxY), let actual = Self.frame(of: window) else {
            return false
        }
        let position = accessibilityPoint(NSPoint(x: frame.minX, y: frame.maxY), primaryMaxY: primaryMaxY)
        return abs(actual.width - frame.width) < 3 && abs(actual.height - frame.height) < 3
            && abs(actual.minX - position.x) < 3 && abs(actual.minY - position.y) < 3
    }

    private nonisolated static func requestFrame(_ frame: NSRect, of window: AXUIElement, primaryMaxY: CGFloat) -> Bool {
        var size = frame.size
        var position = accessibilityPoint(NSPoint(x: frame.minX, y: frame.maxY), primaryMaxY: primaryMaxY)
        guard let sizeValue = AXValueCreate(.cgSize, &size), let positionValue = AXValueCreate(.cgPoint, &position)
        else { return false }
        guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
        else { return false }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return true
    }
}

private final class WindowPlacementPreviewView: NSView {
    var title = ""
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 15, yRadius: 15)
        FileveroPalette.nsAccent.withAlphaComponent(0.16).setFill()
        shape.fill()
        FileveroPalette.nsAccent.withAlphaComponent(0.8).setStroke()
        shape.lineWidth = 2
        shape.stroke()
        let text = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let size = text.size()
        let rect = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.maxY - 62, width: size.width + 32, height: 38)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

// MARK: - Compatibility Bridge
public typealias WindowManagementController = AppWindowManager

