import AppKit

// MARK: - KeyboardModifierChord: Modifier Combinations & Drag Chord Registry

public struct KeyboardModifierChord: RawRepresentable, Hashable, Identifiable, Sendable {
    public let rawValue: UInt
    public var id: UInt { rawValue }
    public static let supported: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private static let components: [(NSEvent.ModifierFlags, String, String)] = [
        (.control, "Control", "⌃"),
        (.option, "Option", "⌥"),
        (.shift, "Shift", "⇧"),
        (.command, "Command", "⌘"),
    ]

    public init(rawValue: UInt) {
        self.rawValue = rawValue & Self.supported.rawValue
    }

    public init(_ flags: NSEvent.ModifierFlags) {
        self.init(rawValue: flags.rawValue)
    }

    public var flags: NSEvent.ModifierFlags {
        .init(rawValue: rawValue)
    }

    public var symbols: String {
        Self.components.filter { flags.contains($0.0) }.map(\.2).joined()
    }

    public var title: String {
        Self.components.filter { flags.contains($0.0) }.map(\.1).joined(separator: " + ")
    }

    public var isEmpty: Bool {
        rawValue == 0
    }

    public static let all: [KeyboardModifierChord] = (1..<16).map { bits in
        var flags: NSEvent.ModifierFlags = []
        for (index, component) in components.enumerated() where bits & (1 << index) != 0 {
            flags.insert(component.0)
        }
        return KeyboardModifierChord(flags)
    }.sorted { lhs, rhs in
        let lc = lhs.rawValue.nonzeroBitCount
        let rc = rhs.rawValue.nonzeroBitCount
        return lc == rc ? lhs.rawValue < rhs.rawValue : lc < rc
    }

    public static func legacy(_ name: String) -> KeyboardModifierChord? {
        let values: [String: NSEvent.ModifierFlags] = [
            "control": .control, "option": .option, "shift": .shift, "command": .command,
        ]
        var flags: NSEvent.ModifierFlags = []
        for part in name.lowercased().split(separator: "+") {
            guard let value = values[String(part)] else { return nil }
            flags.insert(value)
        }
        return flags.isEmpty ? nil : KeyboardModifierChord(flags)
    }
}

public enum WheelShortcut: String, CaseIterable, Identifiable {
    case conversions, tools, actions
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .conversions: return "Conversion wheel"
        case .tools: return "File tools wheel"
        case .actions: return "File actions wheel"
        }
    }

    public var storageKey: String {
        switch self {
        case .conversions: return "conversionWheelDragModifierMask"
        case .tools: return "toolsWheelDragModifierMask"
        case .actions: return "actionsWheelDragModifierMask"
        }
    }

    public var legacyKey: String {
        switch self {
        case .conversions: return "convertKey"
        case .tools: return "toolsKey"
        case .actions: return "actionsKey"
        }
    }

    public var defaultChord: KeyboardModifierChord {
        switch self {
        case .conversions: return .init(.shift)
        case .tools: return .init(.command)
        case .actions: return .init(.control)
        }
    }
}

public enum KeyboardModifierPreferences {
    public static func chord(for wheel: WheelShortcut, defaults: UserDefaults = .standard) -> KeyboardModifierChord {
        if let stored = defaults.object(forKey: wheel.storageKey) as? NSNumber {
            let chord = KeyboardModifierChord(rawValue: stored.uintValue)
            if !chord.isEmpty { return chord }
        }
        if let name = defaults.string(forKey: wheel.legacyKey), let chord = KeyboardModifierChord.legacy(name) {
            return chord
        }
        return wheel.defaultChord
    }

    @discardableResult
    public static func set(
        _ chord: KeyboardModifierChord,
        for wheel: WheelShortcut,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !chord.isEmpty,
            !WheelShortcut.allCases.contains(where: { $0 != wheel && self.chord(for: $0, defaults: defaults) == chord })
        else { return false }
        defaults.set(chord.rawValue, forKey: wheel.storageKey)
        defaults.set(chord.title.lowercased().replacingOccurrences(of: " + ", with: "+"), forKey: wheel.legacyKey)
        return true
    }

    public static func available(for wheel: WheelShortcut, defaults: UserDefaults = .standard) -> [KeyboardModifierChord] {
        let reserved = Set(WheelShortcut.allCases.filter { $0 != wheel }.map { chord(for: $0, defaults: defaults) })
        return KeyboardModifierChord.all.filter { !reserved.contains($0) }
    }

    public static func wheel(for flags: NSEvent.ModifierFlags, defaults: UserDefaults = .standard) -> WheelShortcut? {
        let current = KeyboardModifierChord(flags)
        guard !current.isEmpty else { return nil }
        return WheelShortcut.allCases.first { chord(for: $0, defaults: defaults) == current }
    }
}

// MARK: - Compatibility Bridge
public typealias ModifierChord = KeyboardModifierChord
public typealias ModifierPreferences = KeyboardModifierPreferences

