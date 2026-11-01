import Foundation

/// Saved, repeatable processing workflow chaining multiple transformation steps (e.g. Resize -> Convert -> Clean Metadata).
public struct Workflow: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var name: String
    public var steps: [WorkflowStep]
    
    public init(name: String, steps: [WorkflowStep]) {
        self.name = name
        self.steps = steps
    }

    /// Validates whether the initial step of the workflow can accept the incoming file items.
    public func accepts(_ inputs: [URL]) -> Bool {
        steps.first?.accepts(inputs) ?? false
    }
}

/// A discrete transformation stage in an automated pipeline.
public enum WorkflowStep: Codable, Sendable, Equatable, Hashable {
    case convert(format: String)
    /// Constrains the longest dimension to the specified pixel length without upscaling.
    case resize(maxDimension: Int)
    case compress(preset: String)
    case removeMetadata

    public var title: String {
        switch self {
        case .convert(let format): return "Convert to \(format.uppercased())"
        case .resize(let size): return "Fit within \(size) px"
        case .compress(let preset): return preset == "strong" ? "Compress (strong)" : "Compress (balanced)"
        case .removeMetadata: return "Remove metadata"
        }
    }

    public func accepts(_ inputs: [URL]) -> Bool {
        guard !inputs.isEmpty else { return false }
        switch self {
        case .convert(let format):
            return FeatureCatalog.formats(for: inputs).contains(format)
        case .resize:
            return inputs.allSatisfy {
                ImageEngine.resizableExtensions.contains(FeatureCatalog.normalizedExtension($0))
            }
        case .compress:
            return FeatureCatalog.tools(for: inputs).contains(.compress)
        case .removeMetadata:
            return FeatureCatalog.tools(for: inputs).contains(.removeMetadata)
        }
    }

    func request(for inputs: [URL], into targetDirectory: URL) -> ConversionRequest {
        var options = OperationOptions()
        options.outputDirectory = targetDirectory
        options.revealInFinder = false
        
        let operation: Operation
        switch self {
        case .convert(let format):
            operation = .convert(format)
        case .resize(let size):
            let source = FeatureCatalog.normalizedExtension(inputs[0])
            operation = .convert(ImageEngine.writableExtensions.contains(source) ? source : "jpg")
            options.maxImageDimension = size
            options.quality = 0.92
        case .compress(let preset):
            operation = .tool(.compress)
            options.compressionPreset = preset
        case .removeMetadata:
            operation = .tool(.removeMetadata)
            options.metadataRemoveAll = true
            var metadataOpts = ImageMetadataOptions()
            metadataOpts.removeAll = true
            options.imageMetadata = metadataOpts
        }
        
        return ConversionRequest(inputs: inputs, operation: operation, options: options)
    }
}

/// Executes multi-stage workflows atomically in isolated staging directories,
/// committing published files only upon complete chain completion.
public enum WorkflowPipelineEngine {
    
    public static func run(
        _ inputs: [URL],
        workflow: Workflow,
        options: OperationOptions,
        token: CancellationToken,
        nameSuffix: String = "",
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard !workflow.steps.isEmpty else {
            throw FileveroError.invalidInput("Add at least one step to this workflow.")
        }
        guard !inputs.isEmpty else {
            throw FileveroError.invalidInput("Choose at least one file.")
        }
        
        let templateFormatter = try options.outputNameTemplate.map(OutputNameFormatter.init)
        let scratchDirectory = try FileWorkspace.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        
        var currentBatch = inputs
        var activeStepDirectory = scratchDirectory
        let totalStepCount = Double(workflow.steps.count)
        
        for (stepIndex, step) in workflow.steps.enumerated() {
            try token.check()
            guard step.accepts(currentBatch) else {
                let formattedKinds = Set(currentBatch.map { FeatureCatalog.normalizedExtension($0).uppercased() })
                    .sorted()
                    .joined(separator: ", ")
                throw FileveroError.invalidInput("Step \(stepIndex + 1) cannot be used with \(formattedKinds) files.")
            }
            
            activeStepDirectory = scratchDirectory.appendingPathComponent("Step \(stepIndex + 1)", isDirectory: true)
            currentBatch = try ConversionEngine.run(
                step.request(for: currentBatch, into: activeStepDirectory),
                token: token
            ) { stepProgress, statusText in
                let mappedProgress = ProgressTracker.map(
                    stepProgress,
                    from: Double(stepIndex) / totalStepCount * 0.95,
                    to: Double(stepIndex + 1) / totalStepCount * 0.95
                )
                progress(mappedProgress, "Step \(stepIndex + 1) of \(workflow.steps.count) · \(statusText)")
            }
        }
        
        return try commitFinalWorkflowResults(
            currentBatch,
            from: activeStepDirectory,
            sourceURL: inputs[0],
            shouldPreserveOriginalName: inputs.count == 1,
            options: options,
            template: templateFormatter,
            nameSuffix: nameSuffix,
            token: token
        )
    }

    private static func commitFinalWorkflowResults(
        _ outputs: [URL],
        from directory: URL,
        sourceURL: URL,
        shouldPreserveOriginalName: Bool,
        options: OperationOptions,
        template: OutputNameFormatter?,
        nameSuffix: String,
        token: CancellationToken
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let targetDirectory = options.outputDirectory ?? sourceURL.deletingLastPathComponent()
        let transaction = AtomicExportTransaction()
        defer { transaction.cleanUp() }
        
        let stagingArea = try transaction.makeArea(destination: targetDirectory)
        let basePrefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var movedMapping: [String: URL] = [:]
        var stagedOutputURLs: [URL] = []
        
        for output in outputs {
            let relativeParts = String(output.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(basePrefix.count))
                .split(separator: "/")
                .map(String.init)
                
            guard let rootName = relativeParts.first else {
                throw FileveroError.failed("A workflow result could not be located.")
            }
            
            if movedMapping[rootName] == nil {
                var candidateName = rootName
                if shouldPreserveOriginalName, outputs.count == 1, relativeParts.count == 1 {
                    candidateName =
                        sourceURL.deletingPathExtension().lastPathComponent + nameSuffix + "." + output.pathExtension
                }
                let targetURL = stagingArea.directory.appendingPathComponent(candidateName)
                try fileManager.moveItem(at: directory.appendingPathComponent(rootName), to: targetURL)
                movedMapping[rootName] = targetURL
            }
            
            let nestedURL = relativeParts.dropFirst().reduce(movedMapping[rootName]!) { acc, segment in
                acc.appendingPathComponent(segment)
            }
            stagedOutputURLs.append(nestedURL)
        }
        
        try transaction.record(stagedOutputURLs, in: stagingArea)
        return try transaction.publish(token: token, naming: template, sequence: options.outputSequence)
    }
}

public typealias WorkflowEngine = WorkflowPipelineEngine
public typealias WorkflowPipeline = Workflow

