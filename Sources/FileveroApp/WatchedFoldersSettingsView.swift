import AppKit
import FileveroCore
import SwiftUI

// MARK: - WatchedFoldersSettingsView: Folders Whose New Files Run Through a Workflow

struct WatchedFoldersSettingsView: View {
    @ObservedObject var controller: WatchedFolderController = .shared
    @ObservedObject var workflows: WorkflowPipelineStore = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FileveroPageHeading(
                    eyebrow: "Watched Folders",
                    title: "New files take care of themselves.",
                    subtitle: "When a file arrives in a watched folder, Filevero runs a workflow on it and saves the result in the folder’s Filevero subfolder. Originals stay untouched.")

                if workflows.workflows.isEmpty {
                    GroupBox {
                        LText("Create a workflow first: open Home, choose Workflows and select New workflow.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if controller.folders.isEmpty {
                                LText("No folders are watched.").foregroundStyle(.secondary)
                            }
                            ForEach(controller.folders) { folder in
                                row(folder)
                                Divider()
                            }
                            Button {
                                addFolder()
                            } label: {
                                Label("Add Folder…", systemImage: "plus")
                            }
                        }
                        .padding(10)
                    }
                    LText("Only files added after a folder is watched are processed, once they have finished copying. Hidden, temporary and partly downloaded files are skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func row(_ folder: WatchedFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: folder.path.lastPathComponent).lineLimit(1)
                    Text(verbatim: folder.path.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Toggle("Watch", isOn: Binding(get: { folder.isEnabled }, set: { controller.setEnabled($0, for: folder.id) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Watch this folder")
                Button {
                    controller.remove(folder.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Stop watching")
                .accessibilityLabel("Stop watching")
            }
            Picker("Workflow", selection: Binding(get: { folder.workflowID }, set: { controller.setWorkflow($0, for: folder.id) })) {
                if controller.workflow(for: folder) == nil { LText("Choose a workflow").tag(folder.workflowID) }
                ForEach(workflows.workflows) { workflow in Text(verbatim: workflow.name).tag(workflow.id) }
            }
            if !controller.isReachable(folder) {
                Label("This folder can’t be found.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let workflow = workflows.workflows.first else { return }
        controller.add(url, workflow: workflow)
    }
}
