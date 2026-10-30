import AppKit
import SwiftUI

public struct SuccessNotice: Sendable {
    public let title: String
    public let detail: String
    public var files: [URL]

    public init(title: String, detail: String, files: [URL] = []) {
        self.title = title
        self.detail = detail
        self.files = files
    }

    public static func filesReady(_ files: [URL]) -> SuccessNotice {
        SuccessNotice(
            title: files.isEmpty
                ? "Nicely done."
                : "Nicely done. \(files.count) file\(files.count == 1 ? " is" : "s are") ready.",
            detail: files.first?.lastPathComponent ?? L10n.text("Your task is complete."),
            files: files
        )
    }

    public static func action(_ title: String, files: [URL]) -> SuccessNotice {
        SuccessNotice(
            title: title,
            detail: files.count == 1 ? files[0].lastPathComponent : L10n.text("\(files.count) files"),
            files: files
        )
    }
}

@MainActor
public final class SuccessToastController {
    public private(set) var panel: NSPanel?
    private var autoDismissTask: Task<Void, Never>?
    public static let displayDuration: TimeInterval = 3
    public static let fadeAnimationDuration: TimeInterval = 0.28

    public init() {}

    public func show(_ notice: SuccessNotice) {
        dismiss()
        let currentScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let usableBounds = currentScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let dimensions = NSSize(width: min(560, usableBounds.width - 32), height: 88)
        let rect = NSRect(
            x: usableBounds.midX - dimensions.width / 2,
            y: usableBounds.minY + 28,
            width: dimensions.width,
            height: dimensions.height
        )

        let toast = SuccessToastPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toast.title = "Filevero — Complete"
        toast.isReleasedWhenClosed = false
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.level = .floating
        toast.isFloatingPanel = true
        toast.hidesOnDeactivate = false
        toast.animationBehavior = .none
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        toast.contentView = NSHostingView(rootView: SuccessToastView(notice: notice).fileveroLanguage())
        panel = toast

        let timestamp = ProcessInfo.processInfo.systemUptime
        toast.orderFrontRegardless()

        NSAccessibility.post(
            element: toast,
            notification: .announcementRequested,
            userInfo: [.announcement: L10n.text(notice.title), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )

        autoDismissTask = Task { @MainActor [weak self, weak toast] in
            let elapsed = ProcessInfo.processInfo.systemUptime - timestamp
            let remaining = max(0, Self.displayDuration - elapsed)
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let toast, self.panel === toast else { return }
            self.fadeAndClose(toast)
        }
    }

    public func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func fadeAndClose(_ toast: NSPanel) {
        guard FileveroMotion.enabled else {
            dismiss()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 0
        } completionHandler: { [weak self, weak toast] in
            Task { @MainActor in
                guard let self, let toast, self.panel === toast else { return }
                self.dismiss()
            }
        }
    }
}

private final class SuccessToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SuccessToastView: View {
    let notice: SuccessNotice

    var body: some View {
        HStack(spacing: 13) {
            FileveroCheck()
            VStack(alignment: .leading, spacing: 5) {
                LText(notice.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(notice.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !notice.files.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(notice.files)
                }
                .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileveroGlass(radius: 22)
    }
}

// Backward-compatibility bridge
public typealias SuccessStatusToast = SuccessToastController

