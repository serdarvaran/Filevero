import AppKit
import FileveroCore
import SwiftUI

/// Isolated first-run UI regression test: simulated publishers, verified shortcuts, and lifecycle model.
/// Never downloads live tools, touches the user's filesystem tool directory, or requests TCC.
@MainActor
public final class ToolSetupSmokeTest: NSObject, NSApplicationDelegate {
    private let outputDirectory: URL
    private var window: NSWindow?
    private var checksPassed: [String] = []

    public init(output: URL) {
        self.outputDirectory = output
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            var failureMessage: String?
            do {
                try await executeSmokeTest()
            } catch {
                failureMessage = String(describing: error)
            }

            let resultRecord: [String: Any] = [
                "passed": failureMessage == nil,
                "checks": checksPassed,
                "error": failureMessage as Any? ?? NSNull(),
                "scope": "Own-window Return/Escape setup UI, clean/partial/existing tools, failure, cancellation, and retry. Publisher responses are simulated."
            ]

            if let serialized = try? JSONSerialization.data(withJSONObject: resultRecord, options: [.prettyPrinted, .sortedKeys]) {
                try? serialized.write(to: outputDirectory.appendingPathComponent("mac-tool-setup.json"))
            }

            window?.close()
            exit(failureMessage == nil ? 0 : 1)
        }
    }

    private func verify(_ condition: Bool, _ label: String) throws {
        guard condition else {
            throw NSError(
                domain: "Filevero Setup QA",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: label]
            )
        }
        checksPassed.append(label)
    }

    private func pause() async {
        try? await Task.sleep(nanoseconds: 160_000_000)
    }

    private func pressShortcut(_ identifier: String) throws {
        guard let window else {
            throw NSError(domain: "Filevero Setup QA", code: 2)
        }
        let isCancel = (identifier == "SetupCancel")
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: isCancel ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: isCancel ? "\u{1b}" : "\r",
            isARepeat: false,
            keyCode: isCancel ? 53 : 36
        )!

        if !window.performKeyEquivalent(with: keyEvent) {
            window.sendEvent(keyEvent)
        }
        checksPassed.append("Own-window shortcut dispatched: " + identifier)
    }

    private func waitForIdleState(_ coordinator: ExternalToolSetupCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while coordinator.working && Date() < deadline {
            await pause()
        }
        try verify(!coordinator.working, "Setup task returns to an idle, retryable state")
        await pause()
    }

    private func captureScreenshot(_ filename: String) throws {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: outputDirectory.appendingPathComponent(filename))
        }
    }

    private func executeSmokeTest() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let suiteName = "Filevero.SetupQA." + UUID().uuidString
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        testDefaults.set("en", forKey: "appLanguage")

        var simulatedStatus = ToolSetupStatus(mediaReady: false, officeReady: false)
        var mediaInvocations = 0
        var officeInvocations = 0
        var finishedCount = 0
        var officeMode = 0

        let coordinator = ExternalToolSetupCoordinator(
            probe: { simulatedStatus },
            install: { group, token, progress in
                if group == .media {
                    mediaInvocations += 1
                    simulatedStatus.mediaReady = true
                    progress(1, "Media tools are ready.")
                } else {
                    officeInvocations += 1
                    if officeMode == 0 {
                        throw NSError(
                            domain: "Publisher fixture",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Offline fixture: retry setup."]
                        )
                    }
                    if officeMode == 1 {
                        while !token.isCancelled {
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        try token.check()
                    }
                    simulatedStatus.officeReady = true
                    progress(1, "Office tools are ready.")
                }
            }
        )

        let setupWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 80, width: 646, height: 690),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        setupWindow.title = "Filevero First Run QA"
        setupWindow.isReleasedWhenClosed = false
        setupWindow.contentView = NSHostingView(
            rootView: ExternalToolSetupView(
                model: coordinator,
                onDone: { finishedCount += 1 }
            )
            .fileveroLanguage()
            .defaultAppStorage(testDefaults)
        )
        window = setupWindow
        setupWindow.makeKeyAndOrderFront(nil)

        await pause()
        await pause()

        try verify(
            !coordinator.status.ready && coordinator.status.missing == [ToolGroup.media, ToolGroup.office],
            "Clean first-run profile requires both tool groups"
        )
        try captureScreenshot("mac-first-run-tools.png")

        try pressShortcut("SetupContinue")
        await pause()
        try await waitForIdleState(coordinator)

        try verify(
            mediaInvocations == 1 && officeInvocations == 1 && coordinator.status.missing == [ToolGroup.office] && finishedCount == 0,
            "An Office download failure retains installed media and does not finish onboarding"
        )
        try captureScreenshot("mac-first-run-retry.png")

        officeMode = 1
        try pressShortcut("SetupContinue")
        await pause()
        try verify(coordinator.working && mediaInvocations == 1, "Retry skips the completed media group")

        try pressShortcut("SetupCancel")
        try await waitForIdleState(coordinator)
        try verify(
            !coordinator.status.ready && coordinator.message == "Setup cancelled. Existing tools were kept.",
            "Cancellation remains incomplete and keeps existing tools"
        )

        officeMode = 2
        try pressShortcut("SetupContinue")
        await pause()
        try await waitForIdleState(coordinator)
        try verify(
            coordinator.status.ready && mediaInvocations == 1 && officeInvocations == 3 && finishedCount == 0,
            "Only successfully verified groups enable Continue"
        )

        testDefaults.set("tr", forKey: "appLanguage")
        await pause()
        try captureScreenshot("mac-first-run-tools-turkish.png")

        try pressShortcut("SetupContinue")
        try verify(finishedCount == 1 && mediaInvocations == 1, "Continue finishes setup without downloading existing tools")

        simulatedStatus.officeReady = false
        coordinator.refresh()
        try verify(
            !coordinator.status.ready && coordinator.message != "Ready. You can go back to your files.",
            "Removing an external tool clears stale readiness when setup is reopened"
        )
    }
}

// MARK: - Backwards Compatibility Bridge
public typealias ToolSetupSmoke = ToolSetupSmokeTest

