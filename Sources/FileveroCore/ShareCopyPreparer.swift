import Foundation

/// Makes a copy that is safe and light to send: no personal metadata, and images in a widely readable size and format.
public enum ShareCopyPreparer {
    public static let maxImageDimension = 2048
    static let nameSuffix = " - Share"
    private static let webFriendlyImages: Set<String> = ["jpg", "png", "webp"]

    public static func steps(for input: URL) -> [WorkflowStep] {
        guard FileCategory.detect(input) == .image else { return [.removeMetadata] }
        let resize: [WorkflowStep] = [.resize(maxDimension: maxImageDimension), .removeMetadata]
        return webFriendlyImages.contains(FeatureCatalog.normalizedExtension(input))
            ? resize : [.convert(format: "jpg")] + resize
    }

    static func run(
        _ inputs: [URL], options: OperationOptions, token: CancellationToken, progress: @escaping ProgressHandler
    ) throws -> [URL] {
        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            try token.check()
            let workflow = Workflow(name: ToolKind.prepareToShare.title, steps: steps(for: input))
            outputs += try WorkflowPipelineEngine.run(
                [input], workflow: workflow, options: options, token: token, nameSuffix: nameSuffix
            ) { fraction, status in
                progress(ProgressTracker.map(fraction, from: Double(index) / Double(inputs.count),
                                             to: Double(index + 1) / Double(inputs.count)), status)
            }
        }
        return outputs
    }
}
