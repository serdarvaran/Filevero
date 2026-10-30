import FileveroCore
import SwiftUI

// MARK: - WorkflowPipelineStore & WorkflowPipelineViews: Workflow Chain Execution

@MainActor public final class WorkflowPipelineStore: ObservableObject {
    public static let shared = WorkflowPipelineStore()
    private static let key = "workflows"
    private let defaults: UserDefaults
    @Published public private(set) var workflows: [Workflow] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workflows = defaults.decodePreservingUnreadable([Workflow].self, forKey: Self.key) ?? []
    }

    public func save(_ workflow: Workflow) {
        if let index = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[index] = workflow
        } else {
            workflows.append(workflow)
        }
        persist()
    }

    public func delete(_ workflow: Workflow) {
        workflows.removeAll { $0.id == workflow.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(workflows) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

public struct WorkflowPipelinePanel: View {
    @ObservedObject public var state: AppSessionController
    @ObservedObject public var store: WorkflowPipelineStore
    @State private var editing: Workflow?

    @MainActor
    public init(state: AppSessionController, store: WorkflowPipelineStore? = nil) {
        self.state = state
        self.store = store ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.workflows.isEmpty {
                Text("No workflows yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.workflows) { workflow in
                let usable = workflow.accepts(state.inputs)
                HStack(spacing: 6) {
                    Button {
                        state.run(workflow)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: workflow.name).lineLimit(1)
                            LText(usable ? "\(workflow.steps.count) steps" : "Not available for these files")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(!usable || state.inputs.isEmpty)

                    Button {
                        editing = workflow
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
                    .help("Edit workflow")
                    .accessibilityLabel("Edit workflow")
                }
            }
            Button {
                editing = Workflow(
                    name: L10n.text("Prepare images for web"),
                    steps: [.resize(maxDimension: 1600), .convert(format: "webp"), .removeMetadata])
            } label: {
                Label("New workflow…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editing) { workflow in
            WorkflowPipelineEditor(
                workflow: workflow,
                isNew: !store.workflows.contains { $0.id == workflow.id },
                onSave: {
                    store.save($0)
                    editing = nil
                },
                onDelete: {
                    store.delete($0)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
            .fileveroLanguage()
        }
    }
}

public struct WorkflowPipelineEditor: View {
    @State public var workflow: Workflow
    public let isNew: Bool
    public let onSave: (Workflow) -> Void
    public let onDelete: (Workflow) -> Void
    public let onCancel: () -> Void

    private static let formats = Set(FeatureCatalog.allConversions.values.flatMap { $0 }).sorted()
    private var canSave: Bool {
        !workflow.name.trimmingCharacters(in: .whitespaces).isEmpty && !workflow.steps.isEmpty
    }

    public init(
        workflow: Workflow,
        isNew: Bool,
        onSave: @escaping (Workflow) -> Void,
        onDelete: @escaping (Workflow) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _workflow = State(initialValue: workflow)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New workflow" : "Edit workflow").font(.title3.weight(.semibold))
            TextField("Name", text: $workflow.name).textFieldStyle(.roundedBorder)
            Text("Each file runs every step in order. Only the final result is saved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        LText(step.title)
                        Spacer()
                        Button {
                            workflow.steps.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Move up")
                        .accessibilityLabel("Move up")

                        Button {
                            workflow.steps.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == workflow.steps.count - 1)
                        .help("Move down")
                        .accessibilityLabel("Move down")

                        Button {
                            workflow.steps.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help("Remove step")
                        .accessibilityLabel("Remove step")
                    }
                    .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)

                    Divider()
                }
                if workflow.steps.isEmpty {
                    Text("Add at least one step to this workflow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
            .fileveroCard(radius: 12)

            Menu {
                Menu("Convert to") {
                    ForEach(Self.formats, id: \.self) { format in
                        Button(format.uppercased()) { workflow.steps.append(.convert(format: format)) }
                    }
                }
                Menu("Fit within") {
                    ForEach([1080, 1600, 2048, 3840], id: \.self) { size in
                        Button("\(size) px") { workflow.steps.append(.resize(maxDimension: size)) }
                    }
                }
                Button("Compress (balanced)") { workflow.steps.append(.compress(preset: "balanced")) }
                Button("Compress (strong)") { workflow.steps.append(.compress(preset: "strong")) }
                Button("Remove metadata") { workflow.steps.append(.removeMetadata) }
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .fixedSize()

            Spacer(minLength: 0)

            HStack {
                if !isNew {
                    Button("Delete workflow", role: .destructive) { onDelete(workflow) }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(workflow) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(FileveroButtonStyle(.primary, compact: true))
            }
        }
        .padding(22)
        .frame(width: 460, height: 470)
        .fileveroBackdrop()
    }
}

// MARK: - Compatibility Bridge
public typealias WorkflowStore = WorkflowPipelineStore
public typealias WorkflowPanel = WorkflowPipelinePanel
public typealias WorkflowEditor = WorkflowPipelineEditor

