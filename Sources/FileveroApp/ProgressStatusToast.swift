import AppKit
import Combine
import SwiftUI

/// Floating non-activating bezel toast showing batch task or web download progress.
@MainActor
public final class ProgressToastController {
    public private(set) var panel: NSPanel?
    private var progressCancellable: AnyCancellable?

    public init() {}

    public func show(state: AppSessionController) {
        guard panel == nil else { return }
        let targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let usableArea = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let toastWidth = min(560, usableArea.width - 32)
        let rect = NSRect(x: usableArea.midX - toastWidth / 2, y: usableArea.minY + 28, width: toastWidth, height: 104)

        let toastPanel = ProgressToastPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toastPanel.title = "Filevero — Progress"
        toastPanel.isReleasedWhenClosed = false
        toastPanel.isOpaque = false
        toastPanel.backgroundColor = .clear
        toastPanel.hasShadow = true
        toastPanel.level = .floating
        toastPanel.isFloatingPanel = true
        toastPanel.hidesOnDeactivate = false
        toastPanel.animationBehavior = .none
        toastPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let host = NSHostingView(
            rootView: JobProgressView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity).fileveroLanguage()
        )
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        toastPanel.contentView = host
        panel = toastPanel
        toastPanel.orderFrontRegardless()

        progressCancellable = state.$working.combineLatest(state.$error).receive(on: RunLoop.main).sink {
            [weak self, weak toastPanel] working, error in
            guard let self, let toastPanel, self.panel === toastPanel else { return }
            if !working && error == nil {
                self.dismiss()
                return
            }
            var updatedFrame = toastPanel.frame
            updatedFrame.size.height = error == nil ? 104 : 140
            toastPanel.setFrame(updatedFrame, display: true)
        }
    }

    public func dismiss() {
        progressCancellable?.cancel()
        progressCancellable = nil
        let target = panel
        panel = nil
        target?.orderOut(nil)
        target?.close()
    }
}

private final class ProgressToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

public struct JobProgressBar: View {
    @Environment(\.fileveroTheme) private var activeTheme
    @ObservedObject public var state: AppSessionController

    public init(state: AppSessionController) {
        self.state = state
    }

    public var body: some View {
        let _ = activeTheme
        if state.progressIsDeterminate {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ThemeTokenPalette.surfaceFill)
                    Capsule().fill(ThemeTokenPalette.accentGradient)
                        .frame(width: max(0, proxy.size.width * state.progress))
                }
            }
            .frame(height: 5)
            .fileveroAnimation(value: state.progress)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int(state.progress * 100)) percent")
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(height: 5)
                .accessibilityLabel("In progress")
                .accessibilityValue(state.progressLabel)
        }
    }
}

// Backward-compatibility bridge
public typealias ProgressStatusToast = ProgressToastController

