import AppKit
import SwiftUI

public enum EditorKeyboardCommand: Equatable, Sendable {
    case togglePlayback
    case nudge(direction: Int, fine: Bool)
    case beginning, end
    case playRange, markIn, markOut, addMarker, save, confirmCrop

    public static func decode(_ event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "ı", with: "i")
        let command: Self?
        if modifiers == .command, key == "s" {
            command = .save
        } else if modifiers.isEmpty || modifiers == .shift {
            switch event.keyCode {
            case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: command = .confirmCrop
            case 49: command = modifiers == .shift ? .playRange : .togglePlayback
            case 123: command = .nudge(direction: -1, fine: modifiers == .shift)
            case 124: command = .nudge(direction: 1, fine: modifiers == .shift)
            case 115 where modifiers.isEmpty: command = .beginning
            case 119 where modifiers.isEmpty: command = .end
            default:
                command = key == "i" ? .markIn : key == "o" ? .markOut : key == "m" ? .addMarker : nil
            }
        } else {
            command = nil
        }
        return command
    }

    public var acceptsRepeat: Bool {
        if case .nudge = self { return true }
        return false
    }

    public func route(_ event: NSEvent, responder: NSResponder?, perform: (Self) -> Bool) -> NSEvent? {
        guard !Self.preservesControlInput(responder) else { return event }
        if event.isARepeat, !acceptsRepeat { return nil }
        return perform(self) ? nil : event
    }

    public static func preservesControlInput(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView, text.isEditable { return true }
        var view = responder as? NSView
        while let current = view {
            if current is NSControl { return true }
            view = current.superview
        }
        return false
    }

    public static func seekTarget(
        current: Double,
        duration: Double,
        direction: Int,
        fine: Bool,
        video: Bool,
        frameRate: Double
    ) -> Double {
        let step = fine ? (video ? 1 / max(1, frameRate) : 0.1) : 1
        return min(max(0, duration), max(0, current + Double(direction) * step))
    }
}

public struct WorkbenchKeyboardShortcuts: NSViewRepresentable {
    public let enabled: Bool
    public let onCommand: (EditorKeyboardCommand) -> Bool

    public init(enabled: Bool, onCommand: @escaping (EditorKeyboardCommand) -> Bool) {
        self.enabled = enabled
        self.onCommand = onCommand
    }

    public final class MonitorView: NSView {
        public var enabled = false
        public var onCommand: ((EditorKeyboardCommand) -> Bool)?
        private var monitor: Any?

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        public func handle(_ event: NSEvent) -> NSEvent? {
            guard enabled, let window, window.isKeyWindow, NSApp.isActive,
                  event.window === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  !(window.childWindows ?? []).contains(where: { $0.isVisible }),
                  let command = EditorKeyboardCommand.decode(event)
            else { return event }

            if command == .save {
                if event.isARepeat { return nil }
                guard window.makeFirstResponder(nil) else { return event }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, self.enabled, let window, self.window === window,
                          window.isKeyWindow, window.attachedSheet == nil
                    else { return }
                    _ = self.onCommand?(.save)
                }
                return nil
            }
            return command.route(event, responder: window.firstResponder) { onCommand?($0) == true }
        }

        public func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }

    public func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.setAccessibilityElement(false)
        view.enabled = enabled
        view.onCommand = onCommand
        return view
    }

    public func updateNSView(_ view: MonitorView, context: Context) {
        view.enabled = enabled
        view.onCommand = onCommand
    }

    public static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
        view.onCommand = nil
    }
}

// Backward-compatibility alias
public typealias EditorKeyboardShortcuts = WorkbenchKeyboardShortcuts

