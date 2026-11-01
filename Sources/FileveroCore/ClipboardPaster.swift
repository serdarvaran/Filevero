import AppKit
import ApplicationServices

public enum ClipboardPasteResult: Equatable, Sendable {
    case pasted, copiedOnly
}

/// Puts a history item on the pasteboard and, when Filevero may post keyboard events, pastes it into the app
/// that was in front before the picker opened.
public struct ClipboardPaster {
    private let isTrusted: () -> Bool
    private let postCommandV: () -> Void
    private let activate: (NSRunningApplication?) -> Void

    public init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postCommandV: @escaping () -> Void = ClipboardPaster.postCommandVAfterActivation,
        activate: @escaping (NSRunningApplication?) -> Void = { $0?.activate() }
    ) {
        self.isTrusted = isTrusted
        self.postCommandV = postCommandV
        self.activate = activate
    }

    public func paste(
        _ formats: [ClipboardFormat: Data], plainTextOnly: Bool, into app: NSRunningApplication?, pasteboard: NSPasteboard
    ) -> ClipboardPasteResult {
        ClipboardPasteboardCodec.write(formats, plainTextOnly: plainTextOnly, to: pasteboard)
        guard isTrusted() else { return .copiedOnly }
        activate(app)
        postCommandV()
        return .pasted
    }

    // The target app needs a moment to become key again before it receives ⌘V.
    public static func postCommandVAfterActivation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyV: CGKeyCode = 9
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }
}
