import Foundation

/// Shortcuts offered for opening clipboard history. ⇧⌘V is common for pasting without formatting.
public enum ClipboardShortcut: String, CaseIterable, Sendable {
    case controlCommandV = "⌃⌘V"
    case controlOptionCommandV = "⌃⌥⌘V"
    case shiftCommandV = "⇧⌘V"

    // Carbon's virtual key code for V and its modifier masks (cmdKey, shiftKey, optionKey, controlKey).
    public var keyCode: UInt32 { 9 }

    public var carbonModifiers: UInt32 {
        switch self {
        case .controlCommandV: return 0x1000 | 0x100
        case .controlOptionCommandV: return 0x1000 | 0x800 | 0x100
        case .shiftCommandV: return 0x200 | 0x100
        }
    }

    public var conflictWarning: String? {
        self == .shiftCommandV ? "Many apps use ⇧⌘V to paste without formatting." : nil
    }

    public static func stored(_ raw: String?) -> ClipboardShortcut {
        raw.flatMap(ClipboardShortcut.init(rawValue:)) ?? .controlCommandV
    }
}
