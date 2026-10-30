import AppKit
import FileveroCore
import SwiftUI

// MARK: - FolderOrganizationViews: In-Place Batch Rename, Classification & Deduplication

public struct FolderOrganizationViews: View {
    @ObservedObject public var state: AppSessionController
    public let tool: ToolKind
    @State private var inputs: [URL]
    @State private var rename = RenameOptions()
    @State private var mode: OrganizeMode = .month
    @State private var dateSource: FileDateSource = .captured
    @State private var duplicates: [[URL]]?
    @State private var scanToken = CancellationToken()
    @State private var problem: String?
    @State private var applied: AppliedMoves?
    @State private var confirmTrash = false
    @State private var rows: [RenamePreviewRow] = []
    @State private var organizePlan: [FileMove] = []
    @State private var trashing = false
    @State private var suggestions: [URL: String] = [:]
    @State private var useSuggestions = true
    @State private var suggestionProgress: (done: Int, total: Int)?
    @State private var suggestionFailures: [(file: String, reason: String)] = []
    @State private var suggestionTask: Task<Void, Never>?
    private var activeSuggestions: [URL: String] { useSuggestions ? suggestions : [:] }
    @Environment(\.fileveroTheme) private var theme
    private static let visibleRows = 60

    public init(state: AppSessionController, tool: ToolKind, rename: RenameOptions = .init()) {
        self.state = state
        self.tool = tool
        _inputs = State(initialValue: state.inputs)
        _rename = State(initialValue: rename)
    }

    public var body: some View {
        let _ = theme
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                WindowCloseButton().frame(width: 26, height: 26)
                Image(systemName: FeatureCatalog.toolSymbols[tool] ?? "folder")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(FileveroPalette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(
                        FileveroPalette.accentGradient,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    LText(tool.title).font(.system(size: 21, weight: .bold))
                    LText(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                FileveroPill(title: "\(inputs.count) items", symbol: "doc")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 17)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .renameFiles:
                        renameSettings
                        renamePreview
                    case .organizeFiles:
                        organizeSettings
                        organizePreview
                    default:
                        duplicateList
                    }
                    if let problem {
                        Label {
                            LText(problem)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer.padding(.horizontal, 20).padding(.vertical, 15)
        }
        .frame(minWidth: 560, minHeight: 520)
        .fileveroBackdrop()
        .tint(FileveroPalette.accent)
        .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
        .textFieldStyle(.roundedBorder)
        .task(id: tool) {
            if tool == .findDuplicates { await scan() }
        }
        .task(
            id: PreviewKey(
                inputs: inputs, rename: rename, suggestions: activeSuggestions, mode: mode, dateSource: dateSource)
        ) {
            await refreshPreview()
        }
        .onDisappear {
            scanToken.cancel()
            suggestionTask?.cancel()
        }
    }

    private var hint: String {
        switch tool {
        case .renameFiles: return "Preview new names before anything changes."
        case .organizeFiles: return "Move files into folders next to them."
        default: return "Find files with exactly the same contents."
        }
    }

    // MARK: Rename Settings & Preview

    private struct PreviewKey: Equatable {
        let inputs: [URL]
        let rename: RenameOptions
        let suggestions: [URL: String]
        let mode: OrganizeMode
        let dateSource: FileDateSource
    }

    private func refreshPreview() async {
        let urls = inputs
        let options = rename
        let suggested = activeSuggestions
        let mode = mode
        let dateSource = dateSource
        let language = L10n.language
        switch tool {
        case .renameFiles:
            rows = await Task.detached(priority: .userInitiated) {
                BatchRename.preview(urls, options: options, suggestions: suggested)
            }.value
        case .organizeFiles:
            organizePlan = await Task.detached(priority: .userInitiated) {
                FileOrganizer.plan(urls, mode: mode, dateSource: dateSource, language: language)
            }.value
        default:
            break
        }
    }

    private var renameSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name pattern", text: $rename.template)
                ForEach(["{name}", "{n}", "{date}"], id: \.self) { token in
                    Button(token) { rename.template += token }
                }
            }
            HStack {
                TextField("Find", text: $rename.find)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Replace with", text: $rename.replace)
            }
            HStack {
                Picker("Letters", selection: $rename.letterCase) {
                    ForEach(LetterCase.allCases, id: \.self) { LText($0.title).tag($0) }
                }
                Stepper(value: $rename.startNumber, in: 0...99999) {
                    LText("{n} starts at \(rename.startNumber)")
                }
            }
            Picker("{date} uses", selection: $rename.dateSource) {
                ForEach(FileDateSource.allCases, id: \.self) { LText($0.title).tag($0) }
            }
            Divider()
            suggestionControls
        }
        .padding(16)
        .fileveroCard(radius: 18)
    }

    private var renamePreview: some View {
        let conflicts = rows.filter {
            if case .conflict = $0.status { return true }
            return false
        }.count
        return VStack(alignment: .leading, spacing: 6) {
            LText(
                conflicts > 0
                    ? "\(conflicts) names need attention"
                    : "\(rows.filter { $0.status == .ready }.count) files will be renamed"
            )
            .font(.headline)
            .foregroundStyle(conflicts > 0 ? Color.orange : Color.primary)

            ForEach(Array(rows.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    icon(row.status).frame(width: 16)
                    Text(verbatim: row.source.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                        if case .conflict(let reason) = row.status {
                            LText(reason).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            if rows.count > Self.visibleRows {
                LText("and \(rows.count - Self.visibleRows) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func icon(_ status: RenamePreviewRow.Status) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .unchanged:
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
        case .conflict:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    // MARK: Sort into Folders

    private var organizeSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Group", selection: $mode) {
                ForEach(OrganizeMode.allCases, id: \.self) { LText($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode != .type {
                Picker("Date", selection: $dateSource) {
                    ForEach([FileDateSource.captured, .modified, .created], id: \.self) { LText($0.title).tag($0) }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var organizePreview: some View {
        let folders = Dictionary(grouping: organizePlan) { $0.destination.deletingLastPathComponent() }
            .sorted { $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 8) {
            LText("\(folders.count) folders").font(.headline)
            ForEach(folders.prefix(Self.visibleRows), id: \.key) { folder, moves in
                HStack {
                    Image(systemName: "folder").foregroundStyle(FileveroPalette.accentText)
                    Text(verbatim: folder.lastPathComponent)
                    Spacer()
                    LText("\(moves.count) files").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Duplicates

    private var extraCopies: [URL] { (duplicates ?? []).flatMap { $0.dropFirst() } }

    private var duplicateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let duplicates {
                if duplicates.isEmpty {
                    Label {
                        Text("No duplicates found.")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .foregroundStyle(.green)
                } else {
                    LText(
                        "\(duplicates.count) groups · \(ByteCountFormatter.string(fromByteCount: Int64(wastedBytes), countStyle: .file)) in extra copies"
                    )
                    .font(.headline)
                    Text("The oldest file in each group is kept.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(duplicates.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(group.enumerated()), id: \.offset) { index, url in
                                HStack(spacing: 6) {
                                    Image(systemName: index == 0 ? "checkmark.seal" : "doc.on.doc")
                                        .foregroundStyle(index == 0 ? Color.green : Color.secondary)
                                        .frame(width: 16)
                                    Text(verbatim: url.path).lineLimit(1).truncationMode(.head).font(.caption)
                                }
                            }
                        }
                        .padding(10)
                        .fileveroCard()
                    }
                }
            } else {
                ProgressView("Comparing files…").font(.caption)
            }
        }
    }

    private var wastedBytes: Int {
        extraCopies.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func scan() async {
        scanToken.cancel()
        let token = CancellationToken()
        scanToken = token
        duplicates = nil
        problem = nil
        let urls = inputs
        do {
            duplicates = try await Task.detached(priority: .userInitiated) {
                try DuplicateFinder.groups(in: urls, token: token)
            }.value
        } catch {
            if !token.isCancelled {
                problem = error.localizedDescription
                duplicates = []
            }
        }
    }

    private func moveCopiesToTrash() {
        let copies = extraCopies
        trashing = true
        Task {
            let failed = await Task.detached(priority: .userInitiated) { () -> [String] in
                var failed: [String] = []
                for url in copies {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                return failed
            }.value
            trashing = false
            await scan()
            problem =
                failed.isEmpty
                ? nil
                : "\(failed.count) files could not be moved to the Trash: \(failed.prefix(3).joined(separator: ", "))"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let applied {
                Label {
                    LText("\(applied.moves.count) files changed.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .foregroundStyle(.green)
                .font(.callout)

                Button("Undo") {
                    Task {
                        await state.undoLastMoves()
                        guard state.lastMoves == nil else { return }
                        let restored = Dictionary(
                            applied.moves.map { ($0.destination, $0.source) }, uniquingKeysWith: { first, _ in first })
                        inputs = inputs.map { restored[$0] ?? $0 }
                        self.applied = nil
                    }
                }
                .disabled(state.lastMoves != applied || state.movingFiles)
            }
            Spacer()
            switch tool {
            case .findDuplicates:
                Button("Show copies in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(extraCopies)
                }
                .disabled(extraCopies.isEmpty)

                Button("Move copies to Trash…") {
                    confirmTrash = true
                }
                .buttonStyle(FileveroButtonStyle(.primary))
                .disabled(extraCopies.isEmpty || trashing)
                .confirmationDialog(
                    L10n.text("Move \(extraCopies.count) copies to the Trash?"),
                    isPresented: $confirmTrash
                ) {
                    Button("Move to Trash", role: .destructive) { moveCopiesToTrash() }
                } message: {
                    Text("You can put them back from the Trash.")
                }
            default:
                Button {
                    apply()
                } label: {
                    LText(tool == .renameFiles ? "Rename files" : "Sort into folders")
                }
                .buttonStyle(FileveroButtonStyle(.primary))
                .disabled(applied != nil || state.working || state.movingFiles || suggestionProgress != nil)
            }
        }
    }

    // MARK: Apple Intelligence Suggestions

    @ViewBuilder private var suggestionControls: some View {
        switch FileNameSuggester.status {
        case .available:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let progress = suggestionProgress {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                            .frame(width: 110)
                        LText("Reading \(progress.done) of \(progress.total) files…").font(.caption)
                        Button("Stop") { suggestionTask?.cancel() }
                    } else {
                        Button {
                            suggestNames()
                        } label: {
                            Label {
                                LText(suggestions.isEmpty ? "Suggest names from content" : "Suggest again")
                            } icon: {
                                Image(systemName: "sparkles")
                            }
                        }
                        if !suggestions.isEmpty {
                            Toggle("Use suggested names as {name}", isOn: $useSuggestions)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if suggestionProgress == nil, !suggestions.isEmpty || !suggestionFailures.isEmpty {
                    LText("\(suggestions.count) suggestions · \(suggestionFailures.count) files without one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let first = suggestionFailures.first {
                    Text(verbatim: "\(first.file): \(L10n.text(first.reason))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Text("Apple Intelligence reads the files on this Mac; nothing is uploaded. Review every name before renaming.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .unavailable(let reason):
            Label {
                LText(reason)
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func suggestNames() {
        let files = inputs.filter(FileNameSuggester.supports)
        guard !files.isEmpty else {
            problem = "Name suggestions work with images, PDFs and documents."
            return
        }
        suggestionTask?.cancel()
        suggestionFailures = []
        problem = nil
        suggestionProgress = (0, files.count)
        suggestionTask = Task {
            for file in files {
                if Task.isCancelled { break }
                do {
                    suggestions[file] = try await FileNameSuggester.suggest(for: file)
                } catch is CancellationError {
                    break
                } catch {
                    suggestionFailures.append((file.lastPathComponent, error.localizedDescription))
                }
                suggestionProgress = (min(files.count, (suggestionProgress?.done ?? 0) + 1), files.count)
            }
            useSuggestions = true
            suggestionProgress = nil
        }
    }

    private func apply() {
        problem = nil
        let plan: [FileMove]
        do {
            plan =
                tool == .renameFiles
                ? try BatchRename.plan(BatchRename.preview(inputs, options: rename, suggestions: activeSuggestions))
                : FileOrganizer.plan(inputs, mode: mode, dateSource: dateSource, language: L10n.language)
        } catch {
            problem = error.localizedDescription
            return
        }
        Task {
            do {
                let result = try await state.applyMoves(plan, title: tool.title)
                let moved = Dictionary(
                    result.moves.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
                inputs = inputs.map { moved[$0] ?? $0 }
                applied = result
                suggestions = [:]
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Compatibility Bridge
public typealias OrganizeToolView = FolderOrganizationViews

