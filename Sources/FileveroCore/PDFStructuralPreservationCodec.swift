import Foundation
import JavaScriptCore
import PDFKit

/// High-fidelity PDF structural transformation engine.
/// Executes non-rasterizing page manipulations while preserving AcroForms, annotations,
/// and embedded file attachments using an isolated JavaScriptCore environment.
public enum PDFStructuralPreservationCodec {

    /// Applies page selections and rotational transformations across input PDFs.
    ///
    /// - Parameters:
    ///   - inputs: Source PDF file URLs.
    ///   - selections: Zero-based page indices per input document.
    ///   - rotations: Explicit page rotations in degrees keyed by destination page index.
    ///   - token: Cancellation observer.
    /// - Returns: Serialized valid PDF binary data.
    public static func transform(
        _ inputs: [URL],
        selections: [[Int]],
        rotations: [Int: Int] = [:],
        token: CancellationToken = .init()
    ) throws -> Data {
        try token.check()
        guard !inputs.isEmpty, inputs.count == selections.count else {
            throw FileveroError.invalidInput("Choose PDF sources and a page selection for each source.")
        }

        var sourceB64Payloads: [String] = []
        var aggregateBytes: Int64 = 0
        var totalTargetPages = 0

        for (index, url) in inputs.enumerated() {
            try token.check()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 100_000_000 else {
                throw FileveroError.invalidInput(
                    "This PDF is empty, is not a regular file, or exceeds the 100 MB page-editing limit."
                )
            }

            aggregateBytes += Int64(size)
            guard aggregateBytes <= 200_000_000 else {
                throw FileveroError.invalidInput("These PDFs exceed the 200 MB combined page-editing limit.")
            }

            let pageCount = selections[index].count
            guard !selections[index].isEmpty, pageCount <= 10_000 else {
                throw FileveroError.invalidInput("Choose between 1 and 10,000 output pages.")
            }

            totalTargetPages += pageCount
            guard totalTargetPages <= 10_000 else {
                throw FileveroError.invalidInput("Choose no more than 10,000 output pages at once.")
            }

            let fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
            sourceB64Payloads.append(fileData.base64EncodedString())
        }

        let requestPayload: [String: Any] = [
            "sources": sourceB64Payloads,
            "selections": selections,
            "rotations": Dictionary(uniqueKeysWithValues: rotations.map { (String($0.key), $0.value) })
        ]

        let serializedJSON = try JSONSerialization.data(withJSONObject: requestPayload)
        let bridgeRuntime = try CoreRuntime(token: token)
        let encodedOutput = try bridgeRuntime.execute(String(decoding: serializedJSON, as: UTF8.self))

        try token.check()
        guard encodedOutput.count <= 700_000_000,
              let pdfBytes = Data(base64Encoded: encodedOutput),
              pdfBytes.starts(with: Data("%PDF-".utf8)),
              let renderedDocument = PDFDocument(data: pdfBytes),
              renderedDocument.pageCount == totalTargetPages else {
            throw FileveroError.failed("The PDF page writer returned an invalid document. No copy was exported.")
        }

        return pdfBytes
    }

    // MARK: - Private JS Environment Bridge

    private final class CoreRuntime {
        private let context: JSContext
        private let token: CancellationToken
        private var resultPayload: String?
        private var errorReport: String?

        init(token: CancellationToken) throws {
            self.token = token
            guard let context = JSContext() else {
                throw FileveroError.failed("The native PDF runtime could not start.")
            }
            self.context = context

            context.exceptionHandler = { [weak self] _, exception in
                self?.errorReport = exception?.toString() ?? "Unknown PDF runtime error."
            }

            let isCancelledBlock: @convention(block) () -> Bool = { token.isCancelled }
            let completedBlock: @convention(block) (String) -> Void = { [weak self] in self?.resultPayload = $0 }
            let failedBlock: @convention(block) (String) -> Void = { [weak self] in self?.errorReport = $0 }

            context.setObject(isCancelledBlock, forKeyedSubscript: "_fileveroPDFCancelled" as NSString)
            context.setObject(completedBlock, forKeyedSubscript: "_fileveroPDFComplete" as NSString)
            context.setObject(failedBlock, forKeyedSubscript: "_fileveroPDFFailed" as NSString)

            var candidateResourceRoots: [URL] = [Bundle.main.resourceURL].compactMap { $0 }
            #if DEBUG
            let repoResourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
            candidateResourceRoots.append(repoResourceRoot)
            #endif

            guard let resourceFolder = candidateResourceRoots.first(where: { folder in
                ["PDFLib.js", "PDFInterop.js"].allSatisfy {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
            }) else {
                throw FileveroError.missingDependency("the bundled preserving PDF library")
            }

            for scriptFile in ["PDFLib.js", "PDFInterop.js"] {
                try token.check()
                let scriptURL = resourceFolder.appendingPathComponent(scriptFile)
                let sourceContent = try String(contentsOf: scriptURL, encoding: .utf8)
                context.evaluateScript(sourceContent, withSourceURL: scriptURL)
                if let errorReport {
                    throw FileveroError.failed("The native PDF library could not load: \(errorReport)")
                }
            }
        }

        func execute(_ jsonParameter: String) throws -> String {
            try token.check()
            guard let runner = context.objectForKeyedSubscript("FileveroPDF")?.objectForKeyedSubscript("run"),
                  !runner.isUndefined else {
                throw FileveroError.failed("The native PDF writer is unavailable.")
            }

            _ = runner.call(withArguments: [jsonParameter])

            let timeoutThreshold = Date().addingTimeInterval(120)
            while resultPayload == nil, errorReport == nil, Date() < timeoutThreshold {
                try token.check()
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            try token.check()
            if let errorReport {
                if errorReport.hasPrefix("This PDF contains ") {
                    throw FileveroError.unsupported(errorReport)
                }
                throw FileveroError.invalidInput("The PDF could not be safely edited: \(errorReport)")
            }

            guard let finalOutput = resultPayload else {
                throw FileveroError.failed("The native PDF writer did not finish. No copy was exported.")
            }

            return finalOutput
        }
    }
}

// MARK: - Compatibility Bridge
typealias PDFPreservingCodec = PDFStructuralPreservationCodec

