import Combine
import FileveroCore
import Foundation

/// Runs a saved workflow on files that arrive in watched folders. Nothing is watched until the user adds a folder.
@MainActor
final class WatchedFolderController: ObservableObject {
    static let shared = WatchedFolderController()
    private static let key = "watchedFolders"
    private static let interval: TimeInterval = 1

    @Published private(set) var folders: [WatchedFolder] = []
    /// Queues one file through a workflow into an output folder.
    var run: ((Workflow, URL, URL) -> Void)?

    private let defaults: UserDefaults
    private let workflows: WorkflowPipelineStore
    private var scanners: [UUID: FolderWatchScanner] = [:]
    private var timer: Timer?
    private var subscription: AnyCancellable?

    init(defaults: UserDefaults = .standard, workflows: WorkflowPipelineStore? = nil) {
        self.defaults = defaults
        self.workflows = workflows ?? .shared
        folders = defaults.decodePreservingUnreadable([WatchedFolder].self, forKey: Self.key) ?? []
    }

    func start() {
        subscription = workflows.$workflows.sink { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        apply()
    }

    func workflow(for folder: WatchedFolder) -> Workflow? {
        workflows.workflows.first { $0.id == folder.workflowID }
    }

    func isReachable(_ folder: WatchedFolder) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static let limit = 50

    func add(_ path: URL, workflow: Workflow) {
        guard folders.count < Self.limit, !folders.contains(where: { $0.path.standardizedFileURL == path.standardizedFileURL }) else { return }
        update(folders + [WatchedFolder(path: path, workflowID: workflow.id)])
    }

    func remove(_ id: UUID) { update(folders.filter { $0.id != id }) }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        update(folders.map { folder in
            var changed = folder
            if folder.id == id { changed.isEnabled = enabled }
            return changed
        })
    }

    func setWorkflow(_ workflowID: UUID, for id: UUID) {
        update(folders.map { folder in
            var changed = folder
            if folder.id == id { changed.workflowID = workflowID }
            return changed
        })
    }

    private func update(_ next: [WatchedFolder]) {
        folders = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        apply()
    }

    private var active: [WatchedFolder] { folders.filter { $0.isEnabled && workflow(for: $0) != nil } }

    private func apply() {
        let ids = Set(active.map(\.id))
        scanners = scanners.filter { ids.contains($0.key) }
        if ids.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        tick()
    }

    private func tick() {
        for folder in active {
            guard let listing = FolderWatchScanner.list(folder.path) else { continue }
            // Files already in the folder when watching starts (or when it becomes reachable) are left alone.
            guard var scanner = scanners[folder.id] else {
                scanners[folder.id] = FolderWatchScanner(existing: listing)
                continue
            }
            let ready = scanner.scan(listing, at: Date())
            scanners[folder.id] = scanner
            guard let workflow = workflow(for: folder) else { continue }
            for file in ready where workflow.accepts([file]) {
                run?(workflow, file, folder.outputDirectory)
            }
        }
    }
}
