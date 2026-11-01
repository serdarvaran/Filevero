import Foundation

/// Keeps clipboard history in `history.json` and each entry's formats in `blobs/`, readable only by the user.
/// `store` may run on another thread than the rest: it writes only its own entry's files and reads no shared state.
public final class ClipboardHistoryStore: @unchecked Sendable {
    public let directory: URL
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var index: URL { directory.appendingPathComponent("history.json") }
    private var backup: URL { directory.appendingPathComponent("history.backup.json") }
    // Saving deletes only the data of entries the index on disk listed, so the data of an item still on its way
    // into the history is never swept.
    private var indexed: Set<UUID> = []

    private static let extensions: [(ClipboardFormat, String)] = [
        (.plainText, "txt"), (.rtf, "rtf"), (.html, "html"), (.png, "png"), (.fileURLs, "paths"),
    ]

    public static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filevero/Clipboard", isDirectory: true)
    }

    public init(directory: URL = ClipboardHistoryStore.standardDirectory) {
        self.directory = directory
    }

    /// An unreadable index falls back to its backup, then to the saved data itself, so pinned items are never lost
    /// to a damaged file.
    public func load() -> ClipboardHistory {
        let history = read(index) ?? read(backup) ?? recovered()
        let complete = history.entries.filter { entry in
            entry.formats.allSatisfy { FileManager.default.fileExists(atPath: blob(entry.id, $0).path) }
        }
        if complete.count != history.entries.count {
            NSLog("Filevero clipboard history: dropped %d entries with missing data", history.entries.count - complete.count)
        }
        indexed = Set(complete.map(\.id))
        removeOrphans()
        return ClipboardHistory(entries: complete, bootTime: history.bootTime)
    }

    public func save(_ history: ClipboardHistory) throws {
        try prepare()
        let data = try JSONEncoder().encode(history)
        try write(data, to: index)
        try write(data, to: backup)
        let current = Set(history.entries.map(\.id))
        for id in indexed.subtracting(current) {
            try discard(id)
        }
        indexed = current
    }

    public func store(_ formats: [ClipboardFormat: Data], for id: UUID) throws {
        try prepare()
        for (format, data) in formats {
            try write(data, to: blob(id, format))
        }
    }

    public func discard(_ id: UUID) throws {
        for format in ClipboardFormat.allCases where FileManager.default.fileExists(atPath: blob(id, format).path) {
            try FileManager.default.removeItem(at: blob(id, format))
        }
    }

    public func formats(for entry: ClipboardEntry) -> [ClipboardFormat: Data] {
        var result: [ClipboardFormat: Data] = [:]
        for format in entry.formats {
            result[format] = try? Data(contentsOf: blob(entry.id, format))
        }
        return result
    }

    public func removeEverything() throws {
        indexed = []
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func read(_ url: URL) -> ClipboardHistory? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: url))
        } catch {
            NSLog("Filevero could not read %@: %@", url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    /// Rebuilds entries from the data files when no index can be read. Pins and source apps are not in those
    /// files, so recovered items come back unpinned, dated by when their data was written.
    private func recovered() -> ClipboardHistory {
        var found: [UUID: [ClipboardFormat: Data]] = [:]
        var written: [UUID: Date] = [:]
        for file in blobFiles() {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let format = Self.extensions.first(where: { $0.1 == file.pathExtension })?.0,
                  let data = try? Data(contentsOf: file)
            else { continue }
            found[id, default: [:]][format] = data
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            written[id] = max(written[id] ?? .distantPast, date)
        }
        guard !found.isEmpty else { return ClipboardHistory() }
        NSLog("Filevero recovered %d clipboard items from their saved data", found.count)
        let entries = found.map { id, formats in
            var entry = ClipboardEntry(capture: formats, sourceApp: nil, at: written[id] ?? Date())
            entry.id = id
            return entry
        }
        return ClipboardHistory(entries: entries.sorted { $0.created > $1.created })
    }

    private func removeOrphans() {
        let names = Set(indexed.flatMap { id in ClipboardFormat.allCases.map { blob(id, $0).lastPathComponent } })
        for file in blobFiles() where !names.contains(file.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                NSLog("Filevero could not remove unused clipboard data: %@", error.localizedDescription)
            }
        }
    }

    private func blobFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }

    private func blob(_ id: UUID, _ format: ClipboardFormat) -> URL {
        let ext = Self.extensions.first { $0.0 == format }?.1 ?? format.rawValue
        return blobs.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    private func prepare() throws {
        for folder in [directory, blobs] {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
