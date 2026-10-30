import AppKit
import FileveroCore
import SwiftUI

public struct JobRecord: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var inputs: [String]
    public var outputs: [String]
    public var date = Date()

    public init(id: UUID = UUID(), title: String, inputs: [String], outputs: [String], date: Date = Date()) {
        self.id = id
        self.title = title
        self.inputs = inputs
        self.outputs = outputs
        self.date = date
    }
}

@MainActor
public final class AppSessionController: NSObject, ObservableObject {
    @Published public var inputs: [URL] = []
    @Published public var working = false
    @Published public var progress = 0.0
    @Published public var progressIsDeterminate = false
    private var acceptsProgress = false
    @Published public var progressLabel = ""
    @Published public var error: String?
    @Published public var outputs: [URL] = []
    @Published public var activeTool: ToolKind?
    @Published public var activeInputs: [URL] = []
    @Published public var history: [JobRecord] = []
    @Published public var libraryVisible = false
    @Published public var libraryQuery = ""
    @Published public var selectedHistoryID: UUID?
    @Published public var queue = JobQueueState()
    @Published public var lastMoves: AppliedMoves?
    @Published public private(set) var movingFiles = false
    private var batchOutputs: [UUID: [URL]] = [:]
    @Published public var libraryFocusRequest = 0
    public let filePreview = FilePreview()

    public var filteredHistory: [JobRecord] {
        history.filter {
            libraryQuery.isEmpty
                || AppLocalization.matches(
                    ([
                        $0.title,
                        AppLocalization.text($0.title, language: historyDefaults.string(forKey: "appLanguage") ?? "en"),
                    ] + $0.outputs.map { URL(fileURLWithPath: $0).lastPathComponent }).joined(separator: " "),
                    query: libraryQuery,
                    language: historyDefaults.string(forKey: "appLanguage") ?? "en"
                )
        }
    }

    public func preview(_ job: JobRecord) {
        filePreview.show(
            job.outputs.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    public func navigateLibrary(_ direction: Int) {
        let rows = filteredHistory
        guard !rows.isEmpty else { return }
        let old = rows.firstIndex { $0.id == selectedHistoryID }
        selectedHistoryID = rows[min(rows.count - 1, max(0, (old ?? (direction > 0 ? -1 : 1)) + direction))].id
    }

    public func pasteContent(_ pasteboard: NSPasteboard = .general) {
        guard !working else { return }
        do {
            let result = try ClipboardImport.read(pasteboard)
            if let link = result.link {
                onWebDownload?(link, .video)
                return
            }
            inputs = result.urls
            outputs = []
            error = nil
            libraryVisible = false
            history.insert(JobRecord(title: result.label, inputs: [], outputs: result.urls.map(\.path)), at: 0)
            history = Array(history.prefix(50))
            if let data = try? JSONEncoder().encode(history) {
                historyDefaults.set(data, forKey: "history")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public var token = CancellationToken()
    public var onOpenWheel: (() -> Void)?
    public var onChooseFiles: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onWebDownload: ((URL?, WebDownloadMode) -> Void)?
    public var onWebDrop: (([URL]) -> Void)?
    @Published public var webShortcutAvailable = false
    public var onShowTool: ((ToolKind) -> Void)?
    public var onEPUBOptions: (() -> Void)?
    public var onJobStarted: (() -> Void)?
    public var onSuccess: ((SuccessNotice) -> Void)?
    public var toolWindows: [NSWindow] = []
    public var floatShelves: [FloatShelfController] = []
    private var windowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var sharingService: NSSharingService?

    private let historyDefaults: UserDefaults
    // Job status changes arrive per file; writing the whole queue on each one floods UserDefaults in large batches.
    private lazy var queuePersistence = CoalescedSave(interval: .seconds(1)) { [weak self] in self?.writeQueue() }

    public init(defaults: UserDefaults = .standard) {
        historyDefaults = defaults
        super.init()
        if let data = historyDefaults.data(forKey: "history"),
           let items = try? JSONDecoder().decode([JobRecord].self, from: data) {
            history = items
        }
        if let data = historyDefaults.data(forKey: "jobQueue"),
           let saved = try? JSONDecoder().decode(JobQueueState.self, from: data) {
            queue = saved.restored()
        }
        if let data = historyDefaults.data(forKey: "lastFileMoves") {
            lastMoves = try? JSONDecoder().decode(AppliedMoves.self, from: data)
        }
    }

    public func retainToolWindow(_ window: NSWindow) {
        toolWindows.append(window)
        let id = ObjectIdentifier(window)
        windowObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.toolWindows.removeAll { ObjectIdentifier($0) == id }
                if let token = self.windowObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }

    public func select(
        _ operation: FileveroCore.Operation,
        options: FileveroCore.OperationOptions? = nil,
        immediate: Bool = false
    ) {
        var settings = options ?? OperationOptions()
        if options == nil, case .convert(let format) = operation {
            settings = FormatPreferences.shared.options(for: format)
        }
        if case .convert("epub") = operation, inputs.allSatisfy({ FileCategory.detect($0) == .pdf }), !immediate {
            onEPUBOptions?()
            return
        }
        if case .tool(.removeMetadata) = operation, inputs.count > 1 {
            execute(operation, options: settings)
            return
        }
        if case .tool(let kind) = operation, !immediate,
           !([.muteVideo, .extractArchive, .createPDF, .splitPDF, .createArchive, .removeLocation].contains(kind)) {
            onShowTool?(kind)
            return
        }
        execute(operation, options: settings)
    }

    public func execute(
        _ operation: FileveroCore.Operation,
        options: FileveroCore.OperationOptions = .init(),
        inputs: [URL]? = nil
    ) {
        let selected = inputs ?? self.inputs
        guard !selected.isEmpty else { return }
        var opt = options
        opt.revealInFinder = UserDefaults.standard.bool(forKey: "reveal")
        opt.outputNameTemplate = OutputNamePreference.template()
        queue.enqueue(selected, operation: operation, options: opt)
        saveQueue()
        runQueue()
    }

    public func run(_ workflow: Workflow, inputs: [URL]? = nil) {
        let selected = inputs ?? self.inputs
        guard !selected.isEmpty else { return }
        var options = OperationOptions()
        options.revealInFinder = UserDefaults.standard.bool(forKey: "reveal")
        options.outputNameTemplate = OutputNamePreference.template()
        queue.enqueue(selected, workflow: workflow, options: options)
        saveQueue()
        runQueue()
    }

    public func retry(_ job: QueueJob?) {
        if let job { queue.retry(job.id) } else { queue.retryAll() }
        saveQueue()
        runQueue()
    }

    public func cancel(_ job: QueueJob) {
        let current = queue.jobs.first { $0.id == job.id }?.status
        if current == .running {
            token.cancel()
        } else if current == .waiting {
            queue.update(job.id, to: .cancelled)
            saveQueue()
        }
    }

    public func cancelAll() {
        queue.cancelWaiting()
        saveQueue()
        token.cancel()
    }

    public func clearFinishedJobs() {
        queue.clearFinished()
        saveQueue()
    }

    private func saveQueue() {
        queuePersistence.schedule()
    }

    private func writeQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            historyDefaults.set(data, forKey: "jobQueue")
        }
    }

    /// Writes state whose persistence is coalesced; call before the app terminates.
    public func flushPendingState() {
        queuePersistence.flush()
    }

    private func runQueue() {
        guard !working, !movingFiles, let first = queue.next else { return }
        beginJob(first.operationTitle.isEmpty ? first.title : first.operationTitle)
        Task { [self] in
            defer { finishJob() }
            while let job = queue.next {
                await run(job)
            }
        }
    }

    private func run(_ job: QueueJob) async {
        let cancel = CancellationToken()
        token = cancel
        acceptsProgress = true
        let batch = queue.jobs(in: job.batch)
        let position = batch.firstIndex { $0.id == job.id } ?? 0
        activeInputs = batch.flatMap(\.inputs)
        if job.workflow == nil, case .tool(let tool) = job.operation {
            activeTool = tool
        } else {
            activeTool = nil
        }
        queue.update(job.id, to: .running)
        saveQueue()
        do {
            // Jobs run ffmpeg, exiftool and other tools synchronously; keep them off the cooperative pool.
            let result = try await ExecutionPipeline.offload {
                try withGrantedFolderAccess(job.inputs + [job.options.outputDirectory].compactMap { $0 }) {
                    try job.run(token: cancel) { [weak self] value, label in
                        let overall = OperationProgress.map(
                            value,
                            from: Double(position) / Double(batch.count),
                            to: Double(position + 1) / Double(batch.count)
                        )
                        let detail = batch.count > 1 ? "File \(position+1) of \(batch.count) · \(label)" : label
                        Task { @MainActor in
                            self?.receiveProgress(overall, label: detail, token: cancel)
                        }
                    }
                }
            }
            queue.update(job.id, to: .done(result))
            batchOutputs[job.batch, default: []] += result
        } catch {
            queue.update(job.id, to: cancel.isCancelled ? .cancelled : .failed(error.localizedDescription))
        }
        saveQueue()
        if queue.isFinished(job.batch) {
            completeBatch(job.batch)
        }
    }

    private func completeBatch(_ batch: UUID) {
        let jobs = queue.jobs(in: batch)
        let produced = batchOutputs.removeValue(forKey: batch) ?? []
        stopProgressUpdates()
        outputs = produced
        progress = 1
        if !produced.isEmpty {
            history.insert(
                JobRecord(
                    title: jobs.first?.operationTitle ?? "",
                    inputs: jobs.flatMap(\.inputs).map(\.path),
                    outputs: produced.map(\.path)
                ),
                at: 0
            )
            history = Array(history.prefix(50))
            if let data = try? JSONEncoder().encode(history) {
                historyDefaults.set(data, forKey: "history")
            }
            onSuccess?(.filesReady(produced))
            if jobs.first?.options.revealInFinder == true {
                NSWorkspace.shared.activateFileViewerSelecting(produced)
            }
        }
        let failures = jobs.compactMap { job -> String? in
            if case .failed(let message) = job.status { return message }
            return nil
        }
        if jobs.count == 1, let failure = failures.first {
            error = failure
        } else if !failures.isEmpty {
            error = "\(failures.count) of \(jobs.count) files could not be processed. Retry them from the queue."
        }
        let keep = jobs.contains { job in
            switch job.status {
            case .failed, .interrupted: return true
            default: return false
            }
        }
        if !keep {
            queue.removeBatch(batch)
            saveQueue()
        }
    }

    public func beginJob(_ label: String) {
        token = CancellationToken()
        acceptsProgress = true
        error = nil
        outputs = []
        progress = 0
        progressIsDeterminate = false
        progressLabel = label
        activeTool = nil
        activeInputs = []
        working = true
        onJobStarted?()
    }

    public func receiveProgress(_ value: Double, label: String, token: CancellationToken) {
        guard working, acceptsProgress, self.token === token, !token.isCancelled else { return }
        progressIsDeterminate = value.isFinite && value >= 0
        if progressIsDeterminate { progress = min(0.99, max(0, value)) }
        progressLabel = label
    }

    public func stopProgressUpdates() {
        acceptsProgress = false
    }

    public func finishJob() {
        stopProgressUpdates()
        working = false
        runQueue()
    }

    public func perform(_ action: FileAction, urls: [URL]? = nil) {
        let targetURLs = urls ?? inputs
        guard !targetURLs.isEmpty else { return }
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(targetURLs.map(\.path).joined(separator: "\n"), forType: .string) {
                reportSuccess(.action("File paths copied.", files: targetURLs))
            } else {
                error = "Could not copy the selected file paths."
            }
        case .copy:
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects(targetURLs as [NSURL]) {
                reportSuccess(.action("Files copied.", files: targetURLs))
            } else {
                error = "Could not copy the selected files."
            }
        case .airDrop:
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: targetURLs) {
                sharingService = service
                service.delegate = self
                service.perform(withItems: targetURLs)
            } else {
                error = "AirDrop is unavailable on this Mac."
            }
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = L10n.text("Move Here")
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let directory = panel.url {
                move(targetURLs, to: directory)
            }
        case .terminal:
            let directory = ((try? targetURLs[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                ? targetURLs[0] : targetURLs[0].deletingLastPathComponent()
            let preferred = UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
            let app = preferred == "iTerm2"
                ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
                : URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            if let app {
                NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, err in
                    Task { @MainActor in
                        if let err {
                            self?.error = err.localizedDescription
                        } else {
                            self?.reportSuccess(.action("Opened in \(preferred).", files: [directory]))
                        }
                    }
                }
            } else {
                error = "\(preferred) is not installed."
            }
        case .float:
            if UserDefaults.standard.string(forKey: "floatWheelBehavior") == "addToExisting",
               let existing = floatShelves.reversed().first(where: { $0.window?.isVisible == true }) {
                existing.append(targetURLs)
                existing.showWindow(nil)
                reportSuccess(.action("Added to Float.", files: targetURLs))
                return
            }
            let shelf = FloatShelfController(urls: targetURLs)
            shelf.onClose = { [weak self, weak shelf] in
                guard let shelf else { return }
                self?.floatShelves.removeAll { $0 === shelf }
            }
            floatShelves.append(shelf)
            shelf.showWindow(nil)
            reportSuccess(.action("Added to Float.", files: targetURLs))
        }
    }

    private func move(_ sources: [URL], to directory: URL) {
        guard !movingFiles else { return }
        movingFiles = true
        Task {
            // Moves across volumes copy the data, so they run off the main actor.
            let (moved, failure) = await Task.detached(priority: .userInitiated) { () -> ([URL: URL], String?) in
                var moved: [URL: URL] = [:]
                do {
                    for source in sources {
                        var target = directory.appendingPathComponent(source.lastPathComponent)
                        if target.standardizedFileURL == source.standardizedFileURL { continue }
                        if FileManager.default.fileExists(atPath: target.path) {
                            target = OutputFiles.unique(for: source, extension: source.pathExtension, directory: directory)
                        }
                        try FileManager.default.moveItem(at: source, to: target)
                        moved[source] = target
                    }
                    return (moved, nil)
                } catch {
                    return (moved, error.localizedDescription)
                }
            }.value
            movingFiles = false
            if let failure {
                error = failure
            } else {
                reportSuccess(.action("Files moved.", files: sources.map { moved[$0] ?? $0 }))
            }
            inputs = inputs.map { moved[$0] ?? $0 }
            runQueue()
        }
    }

    public func reportSuccess(_ notice: SuccessNotice) {
        error = nil
        onSuccess?(notice)
    }

    @discardableResult
    public func applyMoves(_ plan: [FileMove], title: String) async throws -> AppliedMoves {
        guard !working, !movingFiles else { throw FileveroError.invalidInput("Wait for the current task to finish.") }
        movingFiles = true
        defer {
            movingFiles = false
            runQueue()
        }
        let folders = Array(
            Set(
                plan.flatMap {
                    [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
                }
            )
        )
        let applied = try await Task.detached(priority: .userInitiated) {
            try withGrantedFolderAccess(folders) {
                try FileMoveEngine.apply(plan, title: title)
            }
        }.value
        rememberMoves(applied)
        let moved = Dictionary(
            applied.moves.map { ($0.source, $0.destination) },
            uniquingKeysWith: { first, _ in first }
        )
        inputs = inputs.map { moved[$0] ?? $0 }
        let listed = applied.moves.prefix(200)
        history.insert(
            JobRecord(title: title, inputs: listed.map(\.source.path), outputs: listed.map(\.destination.path)),
            at: 0
        )
        history = Array(history.prefix(50))
        if let data = try? JSONEncoder().encode(history) {
            historyDefaults.set(data, forKey: "history")
        }
        reportSuccess(.action("\(applied.moves.count) files changed.", files: applied.moves.map(\.destination)))
        return applied
    }

    public func undoLastMoves() async {
        guard let applied = lastMoves, !working, !movingFiles else { return }
        movingFiles = true
        defer {
            movingFiles = false
            runQueue()
        }
        let folders = Array(
            Set(
                applied.moves.flatMap {
                    [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
                }
            )
        )
        do {
            try await Task.detached(priority: .userInitiated) {
                try withGrantedFolderAccess(folders) {
                    try FileMoveEngine.undo(applied)
                }
            }.value
            let restored = Dictionary(
                applied.moves.map { ($0.destination, $0.source) },
                uniquingKeysWith: { first, _ in first }
            )
            inputs = inputs.map { restored[$0] ?? $0 }
            rememberMoves(nil)
            reportSuccess(.action("Changes undone.", files: applied.moves.map(\.source)))
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func forgetLastMoves() {
        rememberMoves(nil)
    }

    private static let maximumStoredMovesBytes = 512 * 1024

    private func rememberMoves(_ applied: AppliedMoves?) {
        lastMoves = applied
        if let applied, let data = try? JSONEncoder().encode(applied), data.count <= Self.maximumStoredMovesBytes {
            historyDefaults.set(data, forKey: "lastFileMoves")
        } else {
            historyDefaults.removeObject(forKey: "lastFileMoves")
        }
    }

    public func recordWebDownload(_ files: [URL], site: String) {
        history.insert(
            JobRecord(title: "Download · \(site)", inputs: files.map(\.path), outputs: files.map(\.path)),
            at: 0
        )
        history = Array(history.prefix(50))
        if let data = try? JSONEncoder().encode(history) {
            historyDefaults.set(data, forKey: "history")
        }
        reportSuccess(.filesReady(files))
    }
}

public func withGrantedFolderAccess<T>(_ urls: [URL], _ action: () throws -> T) throws -> T {
    func acquire(_ index: Int) throws -> T {
        guard index < urls.count else { return try action() }
        return try FolderAccessPreferences.withAccess(to: urls[index]) { try acquire(index + 1) }
    }
    return try acquire(0)
}

extension AppSessionController: NSSharingServiceDelegate {
    nonisolated public func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let files = items.compactMap { $0 as? URL }
        Task { @MainActor [weak self] in
            self?.sharingService = nil
            self?.reportSuccess(.action("Shared with AirDrop.", files: files))
        }
    }

    nonisolated public func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let description = (error as NSError).code == NSUserCancelledError ? nil : error.localizedDescription
        Task { @MainActor [weak self] in
            self?.error = description
            self?.sharingService = nil
        }
    }
}

public enum FileAction: String, CaseIterable, Sendable {
    case airDrop, float, copy, move, copyPath, terminal

    public var title: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    public var symbol: String {
        switch self {
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .float: return "rectangle.on.rectangle"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        }
    }
}

// Backward-compatibility alias
public typealias AppState = AppSessionController

