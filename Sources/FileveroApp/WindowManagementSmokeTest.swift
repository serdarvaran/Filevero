import AppKit
import ApplicationServices
import Darwin
import FileveroCore

/// Native input verification for window arrangement shortcuts.
/// Only moves a separately launched Filevero fixture; normal app runs never synthesize input or enter this flow.
@MainActor
public final class WindowManagementSmokeTestDelegate: NSObject, NSApplicationDelegate {
    private let managerPID: pid_t
    private let outputDirectory: URL
    private var fixtureApp: NSRunningApplication?
    private var fixtureWindowElement: AXUIElement?
    private var executionLog: [[String: Any]] = []
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var currentCursorPoint = CGPoint.zero
    private var isMouseDown = false
    private var activeHeldKey: CGKeyCode?
    private var isInterrupted = false
    private var dispatchSignals: [DispatchSourceSignal] = []
    private var initialPointerLocation: CGPoint?

    private var minimumFixtureWidth: CGFloat {
        guard let index = CommandLine.arguments.firstIndex(of: "--minimum-window-width"),
              index + 1 < CommandLine.arguments.count,
              let parsed = Double(CommandLine.arguments[index + 1]), parsed.isFinite
        else { return 160 }
        return min(1200, max(160, parsed))
    }

    private struct VerificationFailure: Error, CustomStringConvertible {
        let description: String
    }

    public init(managerPID: pid_t, output: URL) {
        self.managerPID = managerPID
        self.outputDirectory = output
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            signalSource.setEventHandler { [weak self] in
                self?.isInterrupted = true
            }
            signalSource.resume()
            dispatchSignals.append(signalSource)
        }

        Task {
            var exitStatus: Int32 = 0
            do {
                try await executeWindowManagementVerification()
                try recordResults(passed: true, failureMessage: nil)
            } catch {
                exitStatus = 1
                try? recordResults(passed: false, failureMessage: String(describing: error))
            }
            performCleanup()
            exit(exitStatus)
        }
    }

    private func requireAssertion(_ condition: Bool, _ failureReason: String) throws {
        guard condition else { throw VerificationFailure(description: failureReason) }
    }

    private func pause(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        try requireAssertion(!isInterrupted, "Native test was interrupted; input was released.")
    }

    private func executeWindowManagementVerification() async throws {
        try requireAssertion(
            AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            "Filevero needs its own \(AppWindowManager.permissionName) permission; no input was posted."
        )
        try requireAssertion(
            NSEvent.pressedMouseButtons == 0 &&
            CGEventSource.flagsState(.combinedSessionState).intersection([
                .maskCommand, .maskShift, .maskControl, .maskAlternate
            ]).isEmpty,
            "Release the mouse and modifiers before testing."
        )

        initialPointerLocation = CGEvent(source: nil)?.location
        let currentExecutableURL = Bundle.main.executableURL?.standardizedFileURL

        guard let manager = NSRunningApplication(processIdentifier: managerPID) else {
            throw VerificationFailure(description: "The selected Filevero manager is not running.")
        }

        try requireAssertion(
            managerPID != ProcessInfo.processInfo.processIdentifier &&
            manager.executableURL?.standardizedFileURL == currentExecutableURL,
            "The manager must be the same installed Filevero executable."
        )

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.arguments = [
            "--window-management-fixture",
            "--minimum-window-width",
            String(Double(minimumFixtureWidth))
        ]
        openConfig.createsNewApplicationInstance = true
        openConfig.activates = false

        fixtureApp = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: openConfig)
        guard let fixture = fixtureApp else {
            throw VerificationFailure(description: "Fixture did not launch.")
        }

        try requireAssertion(
            fixture.executableURL?.standardizedFileURL == currentExecutableURL,
            "Fixture executable differs from installed Filevero."
        )

        let axApp = AXUIElementCreateApplication(fixture.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        for _ in 0..<40 {
            let windows = AppWindowManager.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
            fixtureWindowElement = windows.first {
                AppWindowManager.attribute($0, kAXTitleAttribute) as? String == "Filevero Window Layout Fixture"
            }
            if fixtureWindowElement != nil { break }
            try await pause(100)
        }

        guard let windowElement = fixtureWindowElement, let primaryScreen = NSScreen.screens.first else {
            throw VerificationFailure(description: "The disposable fixture window is unavailable.")
        }
        AXUIElementSetMessagingTimeout(windowElement, 0.2)

        for (idx, placement) in WindowPlacement.allCases.enumerated() {
            try await executeGesture(
                window: windowElement,
                placement: placement,
                index: idx,
                screen: primaryScreen,
                cancel: false
            )
        }

        try await executeGesture(
            window: windowElement,
            placement: .rightHalf,
            index: 4,
            screen: primaryScreen,
            cancel: false,
            resize: true
        )

        try await executeGesture(
            window: windowElement,
            placement: .leftHalf,
            index: 3,
            screen: primaryScreen,
            cancel: true
        )
    }

    private func executeGesture(
        window: AXUIElement,
        placement: WindowPlacement,
        index: Int,
        screen: NSScreen,
        cancel: Bool,
        resize: Bool = false
    ) async throws {
        guard let fixture = fixtureApp, !fixture.isTerminated else {
            throw VerificationFailure(description: "Fixture exited.")
        }

        let workArea = screen.visibleFrame
        let initialBounds = CGRect(
            x: workArea.minX + 70,
            y: workArea.midY - 210,
            width: min(max(620, minimumFixtureWidth), workArea.width - 140),
            height: 420
        )

        try requireAssertion(AppWindowManager.setFrame(initialBounds, of: window), "Fixture could not be prepared.")
        fixture.activate(options: [.activateIgnoringOtherApps])
        try await pause(200)

        guard let currentFrame = AppWindowManager.frame(of: window) else {
            throw VerificationFailure(description: "Fixture bounds are unavailable.")
        }

        let dragOrigin = resize
            ? CGPoint(x: currentFrame.maxX - 3, y: currentFrame.maxY - 3)
            : CGPoint(x: currentFrame.midX, y: currentFrame.minY + 14)

        var hitElement: AXUIElement?
        let systemWideAX = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideAX, 0.2)
        try requireAssertion(
            AXUIElementCopyElementAtPosition(systemWideAX, Float(dragOrigin.x), Float(dragOrigin.y), &hitElement) == .success,
            "Fixture drag origin cannot be hit-tested."
        )

        var hitPID: pid_t = 0
        if let hit = hitElement {
            _ = AXUIElementGetPid(hit, &hitPID)
        }
        try requireAssertion(hitPID == fixture.processIdentifier, "Fixture is covered by another app; no input was posted.")

        let isCommandModifier = (index % 2 != 0)
        let keyVirtualCode: CGKeyCode = isCommandModifier ? 55 : 56
        let modifierFlagMask: CGEventFlags = isCommandModifier ? .maskCommand : .maskShift

        defer { releaseActiveInput() }

        dispatchMouse(.mouseMoved, dragOrigin)
        dispatchMouse(.leftMouseDown, dragOrigin)
        isMouseDown = true
        try await pause(100)

        for step in 1...6 {
            dispatchMouse(.leftMouseDragged, CGPoint(x: dragOrigin.x + CGFloat(step) * 5, y: dragOrigin.y + CGFloat(step) * 3))
            try await pause(35)
        }

        dispatchKeyboard(keyVirtualCode, down: true, flags: modifierFlagMask)
        activeHeldKey = keyVirtualCode
        dispatchMouse(.leftMouseDragged, CGPoint(x: dragOrigin.x + 40, y: dragOrigin.y + 28), flags: modifierFlagMask)

        var arrangementWheelBounds: CGRect?
        for _ in 0..<40 {
            arrangementWheelBounds = retrieveWindowBounds(pid: managerPID, title: "Filevero Window Management")
            if arrangementWheelBounds != nil { break }
            try await pause(50)
        }

        guard let wheelRect = arrangementWheelBounds else {
            throw VerificationFailure(description: "The live window arrangement wheel did not appear.")
        }

        let placementCount = WindowPlacement.allCases.count
        let columns = placementCount <= 4 ? 2 : 3
        let rows = max(1, Int(ceil(Double(placementCount) / Double(columns))))
        let cellWidth = (wheelRect.width - 24) / CGFloat(columns)
        let cellHeight = (wheelRect.height - 58) / CGFloat(rows)

        let targetCenter = CGPoint(
            x: wheelRect.minX + 12 + CGFloat(index % columns) * cellWidth + (cellWidth - 5) / 2,
            y: wheelRect.minY + 46 + CGFloat(index / columns) * cellHeight + (cellHeight - 5) / 2
        )

        for step in 1...8 {
            let ratio = CGFloat(step) / 8
            let startPt = currentCursorPoint
            dispatchMouse(
                .leftMouseDragged,
                CGPoint(x: startPt.x + (targetCenter.x - startPt.x) * ratio, y: startPt.y + (targetCenter.y - startPt.y) * ratio),
                flags: modifierFlagMask
            )
            try await pause(30)
        }

        dispatchMouse(.leftMouseDragged, targetCenter, flags: modifierFlagMask)
        try await pause(180)

        if executionLog.isEmpty {
            try captureWheelScreenshot(pid: managerPID)
            if CommandLine.arguments.contains("--hold-for-capture") {
                try await pause(6000)
            }
        }

        if cancel {
            dispatchKeyboard(53, down: true, flags: modifierFlagMask)
            try await pause(80)
            dispatchKeyboard(53, down: false, flags: modifierFlagMask)
            try await pause(100)
        }

        dispatchKeyboard(keyVirtualCode, down: false)
        activeHeldKey = nil
        try await pause(100)

        if !cancel {
            try requireAssertion(
                retrieveWindowBounds(pid: managerPID, title: "Filevero Window Management") != nil,
                "Releasing the modifier dismissed the wheel unexpectedly."
            )
        }

        dispatchMouse(.leftMouseUp, targetCenter)
        isMouseDown = false

        let expectedRect = cancel
            ? initialBounds
            : placement.frame(in: workArea, scale: screen.backingScaleFactor, minimumSize: CGSize(width: minimumFixtureWidth, height: 120))

        let axTargetPoint = AppWindowManager.accessibilityPoint(CGPoint(x: expectedRect.minX, y: expectedRect.maxY))
        var actualRect: CGRect?

        for _ in 0..<40 {
            actualRect = AppWindowManager.frame(of: window)
            if let rect = actualRect,
               abs(rect.width - expectedRect.width) < 3,
               abs(rect.height - expectedRect.height) < 3,
               cancel || (abs(rect.minX - axTargetPoint.x) < 3 && abs(rect.minY - axTargetPoint.y) < 3)
            {
                break
            }
            try await pause(50)
        }

        guard let finalRect = actualRect else {
            throw VerificationFailure(description: "Fixture disappeared after drag operation.")
        }

        try requireAssertion(
            abs(finalRect.width - expectedRect.width) < 3 &&
            abs(finalRect.height - expectedRect.height) < 3 &&
            (cancel || abs(finalRect.minX - axTargetPoint.x) < 3 && abs(finalRect.minY - axTargetPoint.y) < 3),
            "\(cancel ? "Escape" : placement.rawValue) did not apply expected bounds: \(finalRect)"
        )

        try requireAssertion(
            retrieveWindowBounds(pid: managerPID, title: "Filevero Window Management") == nil,
            "Window wheel remained open after mouse up."
        )

        executionLog.append([
            "placement": cancel ? "escape" : placement.rawValue,
            "modifier": isCommandModifier ? "command" : "shift",
            "gesture": resize ? "resizeBorder" : "titleBar",
            "actual": [finalRect.minX, finalRect.minY, finalRect.width, finalRect.height],
            "passed": true
        ])

        try await pause(120)
    }

    private func dispatchMouse(_ type: CGEventType, _ location: CGPoint, flags: CGEventFlags = []) {
        currentCursorPoint = location
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        )
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func dispatchKeyboard(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func releaseActiveInput() {
        if isMouseDown {
            dispatchMouse(.leftMouseUp, currentCursorPoint)
            isMouseDown = false
        }
        if let key = activeHeldKey {
            dispatchKeyboard(key, down: false)
            activeHeldKey = nil
        }
    }

    private func queryWindowInfo(pid: pid_t, title: String) -> [String: Any]? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windowList.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
            $0[kCGWindowName as String] as? String == title
        }
    }

    private func retrieveWindowBounds(pid: pid_t, title: String) -> CGRect? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        let matchingWindows = (AppWindowManager.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            AppWindowManager.attribute($0, kAXTitleAttribute) as? String == title
        }
        if matchingWindows.count == 1, let frame = AppWindowManager.frame(of: matchingWindows[0]) {
            return frame
        }
        guard let info = queryWindowInfo(pid: pid, title: title),
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    private func captureWheelScreenshot(pid: pid_t) throws {
        guard let winNumber = queryWindowInfo(pid: pid, title: "Filevero Window Management")?[kCGWindowNumber as String] as? NSNumber,
              let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, winNumber.uint32Value, [.boundsIgnoreFraming, .bestResolution])
        else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmap.representation(using: .png, properties: [:]) {
            try pngData.write(to: outputDirectory.appendingPathComponent("mac-window-management.png"))
        }
    }

    private func performCleanup() {
        releaseActiveInput()
        fixtureApp?.terminate()
        fixtureApp = nil
        if let original = initialPointerLocation {
            dispatchMouse(.mouseMoved, original)
        }
        for signalSource in dispatchSignals {
            signalSource.cancel()
        }
    }

    private func recordResults(passed: Bool, failureMessage: String?) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let reportData: [String: Any] = [
            "passed": passed,
            "error": failureMessage as Any? ?? NSNull(),
            "checks": executionLog,
            "scope": "Installed Filevero, disposable fixture, all \(WindowPlacement.allCases.count) Shift/Command drags, modifier release, and Escape cancellation."
        ]
        let json = try JSONSerialization.data(withJSONObject: reportData, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outputDirectory.appendingPathComponent("mac-window-management.json"))
    }
}

// MARK: - Backwards Compatibility Bridge
public typealias WindowManagementSmokeDelegate = WindowManagementSmokeTestDelegate

