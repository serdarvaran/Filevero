import AppKit
import FileveroCore
import FileveroUpdates
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PrimaryWorkspaceView: Central Drag-and-Drop & Operation Desk Workspace

public struct PrimaryWorkspaceView: View {
    @ObservedObject public var state: AppSessionController
    @ObservedObject public var updater: SparkleUpdateCoordinator
    @Environment(\.fileveroTheme) private var theme
    @FocusState private var librarySearchFocused: Bool
    @State private var targeted = false
    @State private var historySearch = ""
    @State private var allHistory = false
    @State private var toolsReady = ExternalToolSetup.status.ready
    @State public var actionSection = 0
    @State private var isChoosingArchiveFormat = false

    public var workflows: WorkflowPipelineStore = .shared

    @MainActor
    public init(
        state: AppSessionController,
        updater: SparkleUpdateCoordinator,
        workflows: WorkflowPipelineStore? = nil,
        actionSection: Int = 0
    ) {
        self.state = state
        self.updater = updater
        self.workflows = workflows ?? .shared
        self._actionSection = State(initialValue: actionSection)
    }

    private var formats: [String] { FeatureCatalog.formats(for: state.inputs) }
    private var tools: [ToolKind] { FeatureCatalog.tools(for: state.inputs) }

    private var recent: [JobRecord] {
        let filtered = state.history.filter {
            historySearch.isEmpty
                || AppLocalization.matches(
                    ([$0.title, AppLocalization.text($0.title, language: L10n.language)]
                        + $0.outputs.map { URL(fileURLWithPath: $0).lastPathComponent }).joined(separator: " "),
                    query: historySearch, language: L10n.language)
        }
        return Array(filtered.prefix(allHistory || !historySearch.isEmpty ? 50 : 3))
    }

    public var body: some View {
        let _ = theme
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) {
                    FileveroMark(size: 30)
                    Text(verbatim: "Filevero").font(.system(size: 17, weight: .bold))
                }
                .padding(.bottom, 12)

                navigation("Workspace", symbol: "rectangle.split.3x1", selected: !state.libraryVisible) {
                    state.libraryVisible = false
                }
                navigation("Library", symbol: "tray.full", selected: state.libraryVisible) {
                    state.libraryVisible = true
                }
                Divider()
                navigation("Download from a link", symbol: "link", selected: false) {
                    state.onWebDownload?(WebLinkPayload.clipboardLink(), .video)
                }
                Spacer()
                navigation(toolsReady ? "Tools ready" : "Finish setup", symbol: "shippingbox", selected: false) {
                    NotificationCenter.default.post(name: .showToolSetup, object: nil)
                }
                navigation("Settings", symbol: "gearshape", selected: false) { state.onSettings?() }
            }
            .padding(16)
            .frame(width: 186)
            .frame(maxHeight: .infinity)
            .fileveroGlass(radius: 22)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        LText(state.libraryVisible ? "Library" : "Workspace").font(.system(size: 24, weight: .semibold))
                        Text("Drop it in, shape it, move on.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.pasteContent()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(state.working)

                    Button {
                        state.onChooseFiles?()
                    } label: {
                        Label("Add files", systemImage: "plus")
                    }
                    .disabled(state.working)
                    .buttonStyle(FileveroButtonStyle(.primary, compact: true))
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 6)

                if state.libraryVisible {
                    libraryPage
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if let version = updater.availableVersion {
                                AppUpdateBanner(updater: updater, version: version)
                            }
                            if let error = updater.lastError, updater.repository != nil {
                                LText(error).font(.caption).foregroundStyle(.orange)
                                Button("Update Connection…") {
                                    NotificationCenter.default.post(name: .showUpdateConnection, object: nil)
                                }
                            }
                            if let moves = state.lastMoves {
                                CategoryUndoMovesBanner(state: state, applied: moves)
                            }
                            workspaceFiles
                            JobProgressView(state: state)
                            if JobExecutionQueueView.isRelevant(state.queue) {
                                JobExecutionQueueView(state: state)
                            }
                            if !state.history.isEmpty {
                                historySection
                            }
                        }
                        .padding(22)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !state.libraryVisible {
                operationPanel
            }
        }
        .padding(10)
        .frame(minWidth: 1000, minHeight: 620)
        .fileveroBackdrop()
        .tint(FileveroPalette.accent)
        .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
        .onReceive(NotificationCenter.default.publisher(for: .toolSetupChanged)) { _ in
            toolsReady = ExternalToolSetup.status.ready
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            toolsReady = ExternalToolSetup.status.ready
        }
        .onChange(of: state.libraryFocusRequest) { _ in librarySearchFocused = true }
        .onChange(of: state.inputs) { _ in
            if !state.working {
                state.outputs = []
                state.error = nil
            }
        }
    }

    private func navigation(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                LText(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? FileveroPalette.onAccent : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    Capsule().fill(FileveroPalette.accentGradient).shadow(
                        color: FileveroPalette.accent.opacity(0.3), radius: 6, y: 2)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var workspaceFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Selected files").font(.system(size: 13, weight: .semibold))
                Text("\(state.inputs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !state.inputs.isEmpty {
                    Button("Clear") { state.inputs = [] }.disabled(state.working)
                }
            }
            .padding(14)

            Divider()

            if CategorySelectionGroupsBar.isRelevant(state.inputs) {
                CategorySelectionGroupsBar(state: state).padding(10)
                Divider()
            }

            if state.inputs.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(FileveroPalette.onAccent)
                        .frame(width: 52, height: 52)
                        .background(
                            FileveroPalette.accentGradient,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .shadow(color: FileveroPalette.accent.opacity(0.35), radius: 12, y: 4)
                    Text("Drop files into your workspace").font(.system(size: 18, weight: .medium))
                    Text("Images, videos, documents and more.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose files") { state.onChooseFiles?() }.disabled(state.working)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                        FileveroPalette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
                .padding(12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.inputs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 12) {
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 24)
                            AsyncFileArtwork(url: url).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(verbatim: url.deletingLastPathComponent().abbreviatingWithTildeInPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                state.inputs.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .disabled(state.working)
                            .accessibilityLabel(L10n.text("Remove") + " " + url.lastPathComponent)
                        }
                        .padding(13)
                        if index < state.inputs.count - 1 { Divider() }
                    }
                }
            }
        }
        .fileveroCard(radius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(
                targeted ? FileveroPalette.accent : Color.clear, lineWidth: 2)
        )
        .onDrop(of: WebLinkPayload.providerTypes, isTargeted: $targeted, perform: receiveDrop)
    }

    private var operationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Operation desk").font(.system(size: 17, weight: .semibold))
            Picker("Operation", selection: $actionSection) {
                Text("Convert").tag(0)
                Text("Edit").tag(1)
                Text("Actions").tag(2)
                Text("Workflows").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            if actionSection == 3 {
                ScrollView {
                    WorkflowPipelinePanel(state: state, store: workflows).disabled(state.working)
                }
            } else if state.inputs.isEmpty {
                Label("Add files to see available operations.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        if actionSection == 0 {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(formats, id: \.self) { format in
                                    Button {
                                        state.select(.convert(format))
                                    } label: {
                                        Text(FormatPreferenceItem.label(for: format))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 5)
                                    }
                                }
                            }
                            if formats.isEmpty {
                                Text("No output formats").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Divider().padding(.vertical, 6)
                                OutputNameInspectorPanel(inputs: state.inputs, formats: formats)
                            }
                        } else if actionSection == 1 {
                            ForEach(tools, id: \.self) { tool in
                                Button {
                                    state.select(.tool(tool))
                                } label: {
                                    HStack {
                                        Image(systemName: FeatureCatalog.toolSymbols[tool] ?? "slider.horizontal.3")
                                            .frame(width: 18)
                                        LText(tool.title)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if tools.isEmpty {
                                Text(
                                    state.inputs.contains(where: FolderContents.isFolder)
                                        ? "Use the files inside the folder to see its tools."
                                        : "No tools for this selection"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            ForEach(FeatureCatalog.organizingTools(for: state.inputs), id: \.self) { tool in
                                Button {
                                    if tool == .createArchive {
                                        isChoosingArchiveFormat = true
                                    } else {
                                        state.select(.tool(tool))
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: FeatureCatalog.toolSymbols[tool] ?? "folder").frame(width: 18)
                                        LText(tool.title)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .popover(
                                    isPresented: Binding(
                                        get: { isChoosingArchiveFormat && tool == .createArchive },
                                        set: { isChoosingArchiveFormat = $0 }),
                                    arrowEdge: .leading
                                ) {
                                    archiveFormatChoices
                                }
                            }
                            Divider().padding(.vertical, 6)
                            ForEach(FileAction.allCases, id: \.self) { action in
                                Button {
                                    state.perform(action)
                                } label: {
                                    HStack {
                                        LText(action.title)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .disabled(state.working)
                }
            }
            Spacer(minLength: 0)
            Divider()
            Label("Original stays safe", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 284)
        .frame(maxHeight: .infinity)
        .fileveroGlass(radius: 22)
    }

    private var archiveFormatChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            LText("Archive format").font(.headline)
            ForEach(ArchiveCodec.creatableFormats, id: \.self) { format in
                Button {
                    isChoosingArchiveFormat = false
                    var options = OperationOptions()
                    options.archiveFormat = format
                    state.select(.tool(.createArchive), options: options)
                } label: {
                    Text(ArchiveCodec.fileExtension(for: format).uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(width: 180)
    }

    private var libraryPage: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your Library").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Your recent files, pasted, and ready for another round.").font(.callout).foregroundStyle(.secondary)
                    TextField("Find a file or tool · ⌘F", text: $state.libraryQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($librarySearchFocused)

                    if let error = state.error {
                        HStack {
                            Label(L10n.text(error), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Dismiss") { state.error = nil }
                                .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
                        }
                    }

                    if state.filteredHistory.isEmpty {
                        LText(
                            state.history.isEmpty
                                ? "Your library is empty. Complete a task or paste a file to get started."
                                : "No matches. Try a file name or tool."
                        )
                        .foregroundStyle(.secondary)
                        .padding(20)
                    }

                    ForEach(state.filteredHistory) { job in
                        RecentFileRow(
                            job: job,
                            canReuse: !state.working,
                            onPreview: { state.preview(job) },
                            onReuse: { urls in
                                guard !state.working else { return }
                                state.inputs = urls
                                state.libraryVisible = false
                            }
                        )
                        .fileveroCard(radius: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16).strokeBorder(
                                state.selectedHistoryID == job.id ? FileveroPalette.accent : Color.clear, lineWidth: 1.5
                            )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectedHistoryID = job.id
                            librarySearchFocused = false
                        }
                        .id(job.id)
                    }

                    Text("↑/↓ choose · Space preview · Return use in Filevero")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
            .onChange(of: state.selectedHistoryID) { id in
                if let id { scroll.scrollTo(id) }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your recent files").font(.system(size: 16, weight: .bold, design: .rounded))
                FileveroPill(title: "\(state.history.count)")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your recent files", text: $historySearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(width: 200)
                .fileveroGlassCapsule()
            }
            VStack(spacing: 3) {
                if recent.isEmpty {
                    Text("No matches. Try a file name or tool.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
                ForEach(recent) { job in
                    RecentFileRow(
                        job: job,
                        canReuse: !state.working,
                        onPreview: { state.preview(job) },
                        onReuse: { urls in
                            guard !state.working else { return }
                            state.inputs = urls
                        })
                }
            }
            .padding(7)
            .fileveroCard()

            if state.history.count > 3 && historySearch.isEmpty {
                Button(allHistory ? "Show less" : "See all recent files") { allHistory.toggle() }
                    .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            }
        }
        .fileveroAnimation(value: allHistory)
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !state.working else { return false }
        WebLinkPayload.urls(from: providers) { urls in
            guard !state.working else { return }
            if urls.first?.isFileURL == false {
                state.onWebDrop?(urls)
            } else if !urls.isEmpty {
                state.inputs = urls
            }
        }
        return !providers.isEmpty
    }
}

public struct RecentFileRow: View {
    public let job: JobRecord
    public let canReuse: Bool
    public let onPreview: () -> Void
    public let onReuse: ([URL]) -> Void

    @Environment(\.locale) private var locale
    @State private var hovered = false

    public init(job: JobRecord, canReuse: Bool, onPreview: @escaping () -> Void, onReuse: @escaping ([URL]) -> Void) {
        self.job = job
        self.canReuse = canReuse
        self.onPreview = onPreview
        self.onReuse = onReuse
    }

    private var urls: [URL] { job.outputs.map { URL(fileURLWithPath: $0) } }
    private var available: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }

    public var body: some View {
        HStack(spacing: 12) {
            if let first = urls.first {
                AsyncFileArtwork(url: first)
                    .frame(width: 29, height: 29)
                    .padding(5)
                    .background(FileveroPalette.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(urls.first?.lastPathComponent ?? job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 3) {
                    if available.isEmpty {
                        Text("Moved or removed")
                    } else {
                        LText(job.title)
                        Text(verbatim: "· " + AppLocalization.relativeDate(job.date, language: locale.identifier))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if urls.count > 1 {
                Text("\(urls.count) files").font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onPreview) {
                Image(systemName: "eye").font(.system(size: 13))
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .disabled(available.isEmpty)
            .help("Preview")
            .accessibilityLabel(L10n.text("Preview") + " " + (urls.first?.lastPathComponent ?? "result"))

            Button {
                onReuse(available)
            } label: {
                Image(systemName: "arrow.up.left").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .disabled(available.isEmpty || !canReuse)
            .help(canReuse ? "Use these files again" : "Available after the current task finishes")
            .accessibilityLabel("Use \(urls.first?.lastPathComponent ?? "result") again")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(available)
            } label: {
                Image(systemName: "folder").font(.system(size: 13))
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .disabled(available.isEmpty)
            .help("Show in Finder")
            .accessibilityLabel("Show \(urls.first?.lastPathComponent ?? "result") in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            hovered ? FileveroPalette.fill : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .onHover { hovered = $0 }
        .fileveroAnimation(value: hovered)
    }
}

extension URL {
    fileprivate var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

public struct JobProgressView: View {
    @ObservedObject public var state: AppSessionController

    public init(state: AppSessionController) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 10) {
            if state.working {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Processing your file…").font(.system(size: 13, weight: .semibold, design: .rounded))
                            LText(state.progressLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if state.progressIsDeterminate {
                            Text("\(Int(state.progress * 100))%")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel") { state.cancelAll() }
                            .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                    }
                    JobProgressBar(state: state)
                }
                .padding(17)
                .fileveroCard(radius: 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = state.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Something went wrong.").font(.system(size: 12, weight: .semibold, design: .rounded))
                        LText(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4).textSelection(
                            .enabled)
                    }
                    Spacer()
                    Button {
                        state.error = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
                    .accessibilityLabel("Dismiss error")
                }
                .padding(15)
                .background(
                    Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .fileveroCard(radius: 18)
                .transition(.opacity)
            }
        }
        .fileveroAnimation(value: state.working)
        .fileveroAnimation(value: state.outputs.count)
        .fileveroAnimation(value: state.error != nil)
    }
}

// MARK: - Compatibility Bridge
public typealias HomeView = PrimaryWorkspaceView

