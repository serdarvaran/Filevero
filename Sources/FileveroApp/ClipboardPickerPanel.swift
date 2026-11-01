import AppKit
import FileveroCore
import SwiftUI

// MARK: - ClipboardPickerPanel: Floating History Picker That Leaves the Previous App in Front

/// A non-activating panel takes keystrokes for its search field while the app the user was working in stays
/// frontmost, so the chosen item can be pasted straight back into it.
@MainActor
final class ClipboardPickerPanel: NSPanel, NSWindowDelegate {
    private var keyMonitor: Any?
    private var model: ClipboardPickerModel?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func show(
        controller: ClipboardController, perform: @escaping (ClipboardPickerModel.Action, ClipboardEntry, NSRunningApplication?) -> Void
    ) {
        let target = NSWorkspace.shared.frontmostApplication
        let model = ClipboardPickerModel(
            history: controller.$history.eraseToAnyPublisher(), formats: { controller.formats(for: $0) },
            perform: { [weak self] action, entry in
                self?.dismiss()
                perform(action, entry, target)
            },
            togglePin: { controller.togglePin($0) }, remove: { controller.remove($0) },
            close: { [weak self] in self?.dismiss() })
        model.showActions = { [weak self, weak model] entry in
            guard let self, let model else { return }
            self.showActions(for: entry) { model.perform(.apply($0), entry) }
        }
        self.model = model
        contentView = NSHostingView(rootView: ClipboardPickerView(model: model).fileveroLanguage())
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + 60))
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, self.model?.handle(event) == true else { return event }
            return nil
        }
        makeKeyAndOrderFront(nil)
    }

    private var chooseAction: ((ClipboardAction) -> Void)?

    /// Opens the selected item's actions under the search field, so they can be chosen with the arrow keys.
    private func showActions(for entry: ClipboardEntry, choose: @escaping (ClipboardAction) -> Void) {
        guard let contentView else { return }
        chooseAction = choose
        let menu = NSMenu()
        for action in ClipboardAction.available(for: entry.kind) {
            let item = NSMenuItem(title: L10n.text(action.title), action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 18, y: contentView.isFlipped ? 52 : contentView.bounds.height - 52), in: contentView)
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = ClipboardAction(rawValue: raw) else { return }
        chooseAction?(action)
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model = nil
        chooseAction = nil
        orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
