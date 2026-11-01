import Carbon
import FileveroCore
import Foundation

/// A system-wide Carbon hot key. Every application hot key shares one event target, so the handler only
/// claims presses carrying its own signature.
final class GlobalHotKey {
    private static let signature: OSType = 0x4656_4350
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(shortcut: ClipboardShortcut, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context, GlobalHotKey.identifier(of: event)?.signature == GlobalHotKey.signature
                else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            }, 1, &spec, context, &handler)
        guard installed == noErr,
              RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
                GetApplicationEventTarget(), 0, &hotKey) == noErr
        else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func identifier(of event: EventRef) -> EventHotKeyID? {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        return status == noErr ? identifier : nil
    }
}
