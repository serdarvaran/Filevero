import Foundation

/// Central dispatcher routing high-level conversion requests and tool operations
/// to specialized engine handlers (RasterPipeline, MediaTranscodePipeline, PDFCoreKit, DocumentProcessor, etc.).
public enum RoutingConversionEngine {
    public static func run(
        _ request: ConversionRequest, token: CancellationToken = .init(),
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard !request.inputs.isEmpty else { throw FileveroError.invalidInput("Choose at least one file.") }
        for url in request.inputs {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                throw FileveroError.invalidInput("File not found: \(url.lastPathComponent)")
            }
        }
        let naming = try request.options.outputNameTemplate.map(OutputNameTemplate.init)
        try token.check()
        let transaction = AtomicExportTransaction()
        defer { transaction.cleanUp() }
        let groups: [[URL]]
        if request.operation.combinesInputs { groups = [request.inputs] } else { groups = request.inputs.map { [$0] } }
        for (index, inputs) in groups.enumerated() {
            try token.check()
            let destination = request.options.outputDirectory ?? inputs[0].deletingLastPathComponent()
            let area = try transaction.makeArea(destination: destination)
            var options = request.options
            options.outputDirectory = area.directory
            let staged = ConversionRequest(inputs: inputs, operation: request.operation, options: options)
            let outputs = try perform(staged, token: token) { value, label in
                let detail = groups.count > 1 ? "File \(index+1) of \(groups.count) · \(label)" : label
                progress(
                    OperationProgress.map(
                        value, from: Double(index) / Double(groups.count) * 0.98,
                        to: Double(index + 1) / Double(groups.count) * 0.98), detail)
            }
            try transaction.record(outputs, in: area)
            progress(Double(index + 1) / Double(groups.count) * 0.98, "Prepared \(index+1) of \(groups.count) files")
        }
        progress(0.98, "Saving your files…")
        let outputs = try transaction.publish(token: token, naming: naming, sequence: request.options.outputSequence)
        progress(1, "Done")
        return outputs
    }

    private static func perform(
        _ request: ConversionRequest, token: CancellationToken, progress: @escaping ProgressHandler
    ) throws -> [URL] {
        var outputs: [URL] = []
        switch request.operation {
        case .convert(let format):
            for input in request.inputs {
                try token.check()
                progress(OperationProgress.indeterminate, "Processing \(input.lastPathComponent)…")
                switch FileCategory.detect(input) {
                case .image:
                    outputs += try RasterPipeline.convert(input, to: format, options: request.options, token: token)
                case .video, .audio:
                    outputs += try MediaTranscodePipeline.convert(
                        input, to: format, options: request.options, token: token, progress: progress)
                case .pdf where ["png", "jpg"].contains(format):
                    outputs += try PDFCoreKit.render(
                        input, to: format, options: request.options, token: token, progress: progress)
                default:
                    outputs += try DocumentProcessor.convert(input, to: format, options: request.options, token: token)
                }
            }
        case .tool(let tool):
            progress(OperationProgress.indeterminate, tool.title)
            switch tool {
            case .recognizeText:
                for input in request.inputs {
                    try token.check()
                    outputs += try VisionTextRecognizer.run(
                        input, options: request.options, token: token, progress: progress)
                }
            case .readQRCode:
                outputs = try BarcodeScannerEngine.export(
                    request.inputs, options: request.options, token: token, progress: progress)
            case .createArchive:
                outputs = try SelectionArchive.create(request.inputs, options: request.options, token: token)
            case .watermark:
                for input in request.inputs {
                    try token.check()
                    if FileCategory.detect(input) == .pdf {
                        outputs += try PDFBatchProcessor.run(
                            tool, inputs: [input], options: request.options, token: token, progress: progress)
                    } else {
                        outputs += try RasterBatchProcessor.run(
                            tool, inputs: [input], options: request.options, token: token, progress: progress)
                    }
                }
            case .uniformSize, .createAnimation, .removeLocation:
                outputs = try RasterBatchProcessor.run(
                    tool, inputs: request.inputs, options: request.options, token: token, progress: progress)
            case .pageNumbers, .protectPDF, .unlockPDF, .combineToPDF:
                outputs = try PDFBatchProcessor.run(
                    tool, inputs: request.inputs, options: request.options, token: token, progress: progress)
            case .renameFiles, .organizeFiles, .findDuplicates:
                throw FileveroError.unsupported("\(tool.title) changes files in place and does not export a copy.")
            case .createPDF:
                outputs = try PDFCoreKit.create(
                    inputs: request.inputs, options: request.options, token: token, progress: progress)
            case .mergePDF, .splitPDF, .organizePDF:
                outputs = try PDFCoreKit.tool(
                    tool, inputs: request.inputs, options: request.options, token: token, progress: progress)
            case .extractArchive:
                for input in request.inputs {
                    try token.check()
                    outputs += try DocumentProcessor.extractArchive(input, options: request.options, token: token)
                }
            case .compress, .removeMetadata:
                for input in request.inputs {
                    try token.check()
                    switch FileCategory.detect(input) {
                    case .image:
                        outputs += try RasterPipeline.tool(tool, inputs: [input], options: request.options, token: token)
                    case .video where tool == .removeMetadata && input.pathExtension.lowercased() == "gif":
                        outputs += try RasterPipeline.tool(tool, inputs: [input], options: request.options, token: token)
                    case .pdf:
                        outputs += try PDFCoreKit.tool(
                            tool, inputs: [input], options: request.options, token: token, progress: progress)
                    case .audio, .video:
                        outputs += try MediaTranscodePipeline.tool(
                            tool, inputs: [input], options: request.options, token: token, progress: progress)
                    default:
                        throw FileveroError.unsupported(
                            "This tool does not support \(input.pathExtension.uppercased()) files.")
                    }
                }
            case .editImage, .annotateImage, .frameImage, .cropImage, .createCollage, .redactImage, .removeBackground:
                outputs = try RasterPipeline.tool(tool, inputs: request.inputs, options: request.options, token: token)
            default:
                outputs = try MediaTranscodePipeline.tool(
                    tool, inputs: request.inputs, options: request.options, token: token, progress: progress)
            }
        }
        try token.check()
        try OutputFiles.validate(outputs)
        return outputs
    }
}

// MARK: - Compatibility Bridge
public typealias ConversionEngine = RoutingConversionEngine

