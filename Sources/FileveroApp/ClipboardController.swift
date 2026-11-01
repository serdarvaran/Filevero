import AppKit
import Combine
import FileveroCore

/// Records the general pasteboard into clipboard history while the feature is on, and keeps it on disk.
@MainActor
final class ClipboardController: ObservableObject {
    enum Key {
        static let enabled = "clipboardHistoryEnabled"
        static let clearOnRestart = "clipboardClearOnRestart"
        static let limit = "clipboardLimit"
        static let shortcut = "clipboardShortcut"
        static let excludedApps = "clipboardExcludedApps"
    }

    @Published private(set) var history = ClipboardHistory()
    @Published private(set) var isPaused = false
    @Published private(set) var isRunning = false
    @Published private(set) var shortcutError: String?

    let store: ClipboardHistoryStore
    var onShowPicker: (() -> Void)?

    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var hotKey: GlobalHotKey?
    private var activeShortcut: ClipboardShortcut?
    private var lastChangeCount = 0
    private var observers: [NSObjectProtocol] = []
    // Encoding, hashing and writing a copy happen here, one copy at a time, off the main thread.
    private static let processingQueueName = "app.filevero.clipboard-history"
    private let processing = DispatchQueue(label: ClipboardController.processingQueueName, qos: .utility)
    // Changes on every stop, so a copy that finishes after the feature is turned off is discarded.
    private var generation = 0

    init(store: ClipboardHistoryStore = ClipboardHistoryStore(), defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.defaults = defaults
        self.pasteboard = pasteboard
    }

    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }
    var clearOnRestart: Bool { defaults.object(forKey: Key.clearOnRestart) as? Bool ?? true }
    var limit: Int { defaults.object(forKey: Key.limit) as? Int ?? 200 }
    var shortcut: ClipboardShortcut { .stored(defaults.string(forKey: Key.shortcut)) }
    var excludedApps: [String] { defaults.stringArray(forKey: Key.excludedApps) ?? ClipboardHistory.defaultExcludedApps }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.apply() }
            },
            // Cleared synchronously: after this notification the app may be terminated before a Task runs.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.clearOnRestart else { return }
                    self.update(self.history.removingUnpinned())
                }
            },
        ]
        apply()
    }

    func setEnabled(_ enabled: Bool, keepHistory: Bool = true) {
        if !enabled, !keepHistory {
            stop()
            let store = store
            // Queued behind any copy still being written, so nothing is left behind in the deleted folder.
            processing.sync {
                do {
                    try store.removeEverything()
                } catch {
                    NSLog("Filevero could not delete clipboard history: %@", error.localizedDescription)
                }
            }
        }
        defaults.set(enabled, forKey: Key.enabled)
        apply()
    }

    func togglePause() { isPaused.toggle() }
    func togglePin(_ id: UUID) { update(history.togglingPin(id)) }
    func remove(_ id: UUID) { update(history.removing(id)) }
    func clearUnpinned() { update(history.removingUnpinned()) }
    func clearAll() { update(history.removingAll()) }
    func touch(_ id: UUID) { update(history.touching(id, at: Date())) }
    func formats(for entry: ClipboardEntry) -> [ClipboardFormat: Data] { store.formats(for: entry) }
    func setExcludedApps(_ apps: [String]) {
        objectWillChange.send()
        defaults.set(apps, forKey: Key.excludedApps)
    }

    private func apply() {
        guard isEnabled else {
            stop()
            return
        }
        if !isRunning {
            isRunning = true
            update(store.load().afterBoot(Self.bootTime(), clearOnRestart: clearOnRestart))
            lastChangeCount = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        let trimmed = history.trimmed(toLimit: limit)
        if trimmed != history { update(trimmed) }
        if activeShortcut != shortcut {
            hotKey = nil
            activeShortcut = shortcut
            hotKey = GlobalHotKey(shortcut: shortcut) { [weak self] in self?.onShowPicker?() }
            shortcutError = hotKey == nil ? "Another app already uses \(shortcut.rawValue). Choose a different shortcut." : nil
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        hotKey = nil
        activeShortcut = nil
        shortcutError = nil
        isRunning = false
        isPaused = false
        generation += 1
        history = ClipboardHistory()
    }

    // Pasteboard reads stay on the main thread because NSPasteboard is not documented as thread-safe.
    private func poll() {
        let count = pasteboard.changeCount
        guard isRunning, count != lastChangeCount else { return }
        lastChangeCount = count
        let excluded = Set(excludedApps)
        guard !isPaused, !accessDenied,
              let capture = ClipboardPasteboardCodec.capture(
                pasteboard, frontmostApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excludedApps: excluded)
        else { return }
        let store = store
        let generation = generation
        processing.async { [weak self] in
            guard let entry = Self.save(capture, excludedApps: excluded, in: store) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.insert(entry, generation: generation) }
            }
        }
    }

    private nonisolated static func save(
        _ capture: ClipboardCapture, excludedApps: Set<String>, in store: ClipboardHistoryStore
    ) -> ClipboardEntry? {
        let capture = ClipboardPasteboardCodec.storable(capture)
        guard ClipboardHistory.shouldRecord(capture, excludedApps: excludedApps),
              let formats = ClipboardHistory.fitted(capture.formats)
        else { return nil }
        let entry = ClipboardEntry(capture: formats, sourceApp: capture.sourceApp)
        do {
            try store.store(formats, for: entry.id)
        } catch {
            NSLog("Filevero could not save a clipboard item: %@", error.localizedDescription)
            return nil
        }
        return entry
    }

    private func insert(_ entry: ClipboardEntry, generation: Int) {
        guard isRunning, generation == self.generation else {
            do {
                try store.discard(entry.id)
            } catch {
                NSLog("Filevero could not discard a clipboard item: %@", error.localizedDescription)
            }
            return
        }
        update(history.inserting(entry, limit: limit))
    }

    // Reading a pasteboard the user has denied in Privacy & Security returns nothing; skip it.
    private var accessDenied: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return pasteboard.accessBehavior == .alwaysDeny
    }

    private func update(_ next: ClipboardHistory) {
        history = next
        guard isRunning else { return }
        do {
            try store.save(next)
        } catch {
            NSLog("Filevero could not save clipboard history: %@", error.localizedDescription)
        }
    }

    static func bootTime() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
}
