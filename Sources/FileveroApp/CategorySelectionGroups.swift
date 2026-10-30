import FileveroCore
import SwiftUI

// MARK: - CategorySelectionGroupsBar & CategoryUndoMovesBanner: Selection Filter & Operation Undo

public struct CategorySelectionGroupsBar: View {
    @Environment(\.fileveroTheme) private var theme
    @ObservedObject public var state: AppSessionController
    @State private var includeSubfolders = true

    public init(state: AppSessionController) {
        self.state = state
    }

    public static func isRelevant(_ inputs: [URL]) -> Bool {
        inputs.contains(where: FolderContents.isFolder) || Set(inputs.map(FileCategory.detect)).count > 1
    }

    public var body: some View {
        let _ = theme
        let folders = state.inputs.filter(FolderContents.isFolder)
        let groups = Dictionary(grouping: state.inputs.filter { !FolderContents.isFolder($0) }, by: FileCategory.detect)
            .sorted { $0.value.count > $1.value.count }
        VStack(alignment: .leading, spacing: 10) {
            if !folders.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(FileveroPalette.accentText)
                    LText(
                        folders.count == 1
                            ? "Use the files inside this folder" : "Use the files inside \(folders.count) folders"
                    ).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Include subfolders", isOn: $includeSubfolders).toggleStyle(.checkbox).font(.caption)
                    Button("Use files") { expandFolders() }
                }
            }
            if groups.count > 1 {
                HStack(spacing: 6) {
                    Text("Only:").font(.caption).foregroundStyle(.secondary)
                    ForEach(groups, id: \.key) { category, files in
                        Button {
                            state.inputs = files
                        } label: {
                            Text(verbatim: "\(L10n.text(category.title)) \(files.count)")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(FileveroPalette.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(state.working)
    }

    private func expandFolders() {
        do {
            let files = try FolderContents.files(in: state.inputs, recursive: includeSubfolders)
            guard !files.isEmpty else {
                state.error = "These folders contain no files."
                return
            }
            state.inputs = files
        } catch {
            state.error = error.localizedDescription
        }
    }
}

public struct CategoryUndoMovesBanner: View {
    @Environment(\.fileveroTheme) private var theme
    @ObservedObject public var state: AppSessionController
    public let applied: AppliedMoves

    public init(state: AppSessionController, applied: AppliedMoves) {
        self.state = state
        self.applied = applied
    }

    public var body: some View {
        let _ = theme
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(FileveroPalette.accentText)
            VStack(alignment: .leading, spacing: 2) {
                LText(applied.title).font(.system(size: 12, weight: .semibold))
                LText("\(applied.moves.count) files changed").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { Task { await state.undoLastMoves() } }.disabled(state.working || state.movingFiles)
            Button {
                state.forgetLastMoves()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .fileveroCard()
    }
}

// MARK: - Compatibility Bridge
public typealias SelectionGroupsBar = CategorySelectionGroupsBar
public typealias UndoMovesBanner = CategoryUndoMovesBanner

