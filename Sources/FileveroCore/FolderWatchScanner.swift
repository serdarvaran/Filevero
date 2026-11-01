import Foundation

/// A folder whose new top-level files run through a saved workflow; results go to its Filevero subfolder.
public struct WatchedFolder: Codable, Identifiable, Equatable, Sendable {
    public static let outputFolderName = "Filevero"
    public var id = UUID()
    public var path: URL
    public var workflowID: UUID
    public var isEnabled = true

    public init(path: URL, workflowID: UUID) {
        self.path = path
        self.workflowID = workflowID
    }

    public var outputDirectory: URL { path.appendingPathComponent(Self.outputFolderName, isDirectory: true) }
}

/// Decides which top-level files of a watched folder are new and finished. Files present when watching starts are
/// never processed; a new file, or a new version of a known one, is reported once it has stopped changing.
public struct FolderWatchScanner {
    public struct FileState: Equatable, Sendable {
        public var size: Int64
        public var modified: Date

        public init(size: Int64, modified: Date) {
            self.size = size
            self.modified = modified
        }
    }

    public struct Entry: Sendable {
        public var url: URL
        public var state: FileState

        public init(url: URL, state: FileState) {
            self.url = url
            self.state = state
        }
    }

    public static let settleTime: TimeInterval = 2
    private static let unfinishedExtensions: Set<String> = [
        "part", "partial", "crdownload", "download", "tmp", "temp", "opdownload",
    ]
    private static let systemFiles: Set<String> = ["desktop.ini", "thumbs.db", ".ds_store"]
    private var known: [String: FileState] = [:]
    private var pending: [String: (state: FileState, since: Date)] = [:]

    public init(existing: [Entry]) {
        for entry in existing { known[entry.url.path] = entry.state }
    }

    public static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.isEmpty || name.hasPrefix(".") || name.hasPrefix("~$") || systemFiles.contains(name.lowercased()) {
            return false
        }
        return !unfinishedExtensions.contains(url.pathExtension.lowercased())
    }

    public mutating func scan(_ listing: [Entry], at now: Date) -> [URL] {
        var present = Set<String>()
        var ready: [URL] = []
        for entry in listing {
            let key = entry.url.path
            present.insert(key)
            if !Self.isCandidate(entry.url) || known[key] == entry.state {
                pending[key] = nil
                continue
            }
            guard let waiting = pending[key], waiting.state == entry.state else {
                pending[key] = (entry.state, now)
                continue
            }
            guard now.timeIntervalSince(waiting.since) >= Self.settleTime else { continue }
            pending[key] = nil
            known[key] = entry.state
            ready.append(entry.url)
        }
        known = known.filter { present.contains($0.key) }
        pending = pending.filter { present.contains($0.key) }
        return ready
    }

    /// Reads the folder's top-level regular files; the Filevero results folder and other subfolders are never listed.
    /// Returns nil when the folder cannot be read, so a passing failure is never mistaken for an emptied folder.
    public static func list(_ folder: URL) -> [Entry]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return nil }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return Entry(
                url: url,
                state: FileState(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
