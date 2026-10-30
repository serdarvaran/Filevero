import Foundation

extension Operation {
    /// Indicates whether the specified operation requires aggregating all input files into a single composite task
    /// (e.g., merging PDFs, generating archives or collages) rather than operating per-file.
    public var combinesInputs: Bool {
        if case .tool(let tool) = self {
            return [
                ToolKind.createPDF, .mergePDF, .createCollage, .joinVideos, .readQRCode, .createArchive,
                .createAnimation, .combineToPDF, .joinAudio,
            ].contains(tool)
        }
        return false
    }

    /// Serialized key for persisting the selected operation in user preferences or queued state.
    public var storageKey: String {
        switch self {
        case .convert(let targetFormat):
            return "convert:" + targetFormat
        case .tool(let toolKind):
            return "tool:" + toolKind.rawValue
        }
    }

    public init?(storageKey: String) {
        let components = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2, !components[1].isEmpty else { return nil }
        
        switch components[0] {
        case "convert":
            self = .convert(components[1])
        case "tool":
            guard let kind = ToolKind(rawValue: components[1]) else { return nil }
            self = .tool(kind)
        default:
            return nil
        }
    }
}

/// Represents the index and total scale of an item within a multi-file batch execution,
/// enabling continuous sequence numbering (`{n}`) across jobs.
public struct OutputSequence: Codable, Sendable, Equatable {
    public let index: Int
    public let total: Int
    
    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }
}

/// A discrete unit of scheduled background processing work with serialized parameters,
/// cancellation support, and execution states.
public struct QueueJob: Codable, Identifiable, Sendable {
    public enum Status: Codable, Sendable, Equatable {
        case waiting
        case running
        case done([URL])
        case failed(String)
        case cancelled
        /// The host app terminated while this task was waiting or executing.
        case interrupted

        public var isFinished: Bool {
            switch self {
            case .waiting, .running:
                return false
            default:
                return true
            }
        }

        public var canRetry: Bool {
            switch self {
            case .failed, .cancelled, .interrupted:
                return true
            default:
                return false
            }
        }
    }

    public let id: UUID
    public let batch: UUID
    public let inputs: [URL]
    public let operationKey: String
    public let options: OperationOptions
    /// Non-nil when this task executes a composite multi-step workflow.
    public var workflow: Workflow? = nil
    public var status: Status

    private enum CodingKeys: String, CodingKey {
        case id, batch, inputs, operationKey, options, workflow, status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Sensitive parameters like encryption passwords stay ephemeral in memory only.
        var sanitizedOptions = options
        sanitizedOptions.password = ""
        
        try container.encode(id, forKey: .id)
        try container.encode(batch, forKey: .batch)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(operationKey, forKey: .operationKey)
        try container.encode(sanitizedOptions, forKey: .options)
        try container.encodeIfPresent(workflow, forKey: .workflow)
        try container.encode(status, forKey: .status)
    }

    public var operation: Operation? {
        Operation(storageKey: operationKey)
    }

    public var title: String {
        inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
    }

    public var operationTitle: String {
        workflow?.name ?? operation?.title ?? ""
    }

    public func run(
        token: CancellationToken,
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        if let activeWorkflow = workflow {
            return try WorkflowEngine.run(
                inputs,
                workflow: activeWorkflow,
                options: options,
                token: token,
                progress: progress
            )
        }
        guard let activeOperation = operation else {
            throw FileveroError.invalidInput("This queued job uses an operation this version cannot run.")
        }
        return try ConversionEngine.run(
            .init(inputs: inputs, operation: activeOperation, options: options),
            token: token,
            progress: progress
        )
    }
}

/// Pure data model representing the state of the task execution queue,
/// supporting batch enqueuing, sequential dispatching, cancellation, and recovery.
public struct JobQueueState: Codable, Sendable {
    public typealias Status = QueueJob.Status
    public private(set) var jobs: [QueueJob] = []

    public init() {}

    @discardableResult
    public mutating func enqueue(
        _ inputs: [URL],
        operation: Operation,
        options: OperationOptions
    ) -> UUID {
        append(
            operation.combinesInputs || inputs.count < 2 ? [inputs] : inputs.map { [$0] },
            operationKey: operation.storageKey,
            workflow: nil,
            options: options
        )
    }

    @discardableResult
    public mutating func enqueue(
        _ inputs: [URL],
        workflow: Workflow,
        options: OperationOptions
    ) -> UUID {
        append(inputs.map { [$0] }, operationKey: "workflow", workflow: workflow, options: options)
    }

    private mutating func append(
        _ groups: [[URL]],
        operationKey: String,
        workflow: Workflow?,
        options: OperationOptions
    ) -> UUID {
        let batchId = UUID()
        for (index, group) in groups.enumerated() {
            var taskOptions = options
            if groups.count > 1 {
                taskOptions.outputSequence = OutputSequence(index: index + 1, total: groups.count)
            }
            jobs.append(
                QueueJob(
                    id: UUID(),
                    batch: batchId,
                    inputs: group,
                    operationKey: operationKey,
                    options: taskOptions,
                    workflow: workflow,
                    status: .waiting
                )
            )
        }
        return batchId
    }

    public var next: QueueJob? {
        jobs.first { $0.status == .waiting }
    }

    public var isRunning: Bool {
        jobs.contains { $0.status == .running }
    }

    public func jobs(in batchId: UUID) -> [QueueJob] {
        jobs.filter { $0.batch == batchId }
    }

    public func isFinished(_ batchId: UUID) -> Bool {
        jobs(in: batchId).allSatisfy(\.status.isFinished)
    }

    public mutating func update(_ id: UUID, to status: Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
    }

    public mutating func cancelWaiting() {
        for index in jobs.indices where jobs[index].status == .waiting {
            jobs[index].status = .cancelled
        }
    }

    public mutating func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.canRetry else { return }
        jobs[index].status = .waiting
    }

    public mutating func retryAll() {
        for index in jobs.indices where jobs[index].status.canRetry {
            jobs[index].status = .waiting
        }
    }

    public mutating func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    public mutating func removeBatch(_ batchId: UUID) {
        jobs.removeAll { $0.batch == batchId }
    }

    /// Restores persistent state after application launch, marking incomplete jobs as interrupted.
    public func restored() -> JobQueueState {
        var copy = self
        for index in copy.jobs.indices where !copy.jobs[index].status.isFinished {
            copy.jobs[index].status = .interrupted
        }
        return copy
    }
}

