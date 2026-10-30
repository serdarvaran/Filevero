import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

/// On-device OCR engine utilizing Apple's Vision framework.
/// Produces searchable PDF documents with exact geometric invisible text layers,
/// or extracts plain unicode text while respecting signatures and security restrictions.
public enum VisionTextRecognizer {
    public static let defaultLanguages = ["tr-TR", "en-US"]
    private static let rasterImageExtensions: Set<String> = [
        "jpg", "png", "heic", "tiff", "webp", "bmp", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"
    ]
    private static let renderDPI = 300.0
    private static let maxRenderPixels = 5000.0
    private static let minimumExistingCharacterCount = 40

    public static func supports(_ url: URL) -> Bool {
        let ext = FeatureCatalog.normalizedExtension(url)
        return ext == "pdf" || rasterImageExtensions.contains(ext)
    }

    public static func availableLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    public static let turkishAvailable = (try? availableLanguages().contains("tr-TR")) ?? false

    public static func run(
        _ input: URL,
        options: OperationOptions,
        token: CancellationToken,
        progress: ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard !options.ocrLanguages.isEmpty else {
            throw FileveroError.invalidInput("Choose at least one recognition language.")
        }
        
        let systemLanguages = Set(try availableLanguages())
        let validLanguages = options.ocrLanguages.filter(systemLanguages.contains)
        guard !validLanguages.isEmpty else {
            throw FileveroError.unsupported(
                "This Mac cannot recognize text in the selected language. Update macOS or choose another language."
            )
        }
        
        guard ["pdf", "txt"].contains(options.ocrOutput) else {
            throw FileveroError.invalidInput("Choose a searchable PDF or a text file.")
        }
        
        let pages = FeatureCatalog.normalizedExtension(input) == "pdf"
            ? try extractPDFPages(input, password: options.password)
            : [try extractImagePage(input)]
            
        var recognizedLines = [[RecognizedLine]](repeating: [], count: pages.count)
        var unindexedPageCount = 0
        
        for (index, page) in pages.enumerated() {
            try token.check()
            if page.existingText == nil {
                recognizedLines[index] = try recognize(page.render(), languages: validLanguages)
                unindexedPageCount += 1
            }
            progress(Double(index + 1) / Double(pages.count) * 0.9, "Recognized page \(index + 1) of \(pages.count)")
        }
        
        if options.ocrOutput == "txt" {
            let fullText = zip(pages, recognizedLines).map { page, lines in
                page.existingText ?? lines.map(\.text).joined(separator: "\n")
            }.joined(separator: "\n\n")
            
            guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileveroError.failed("No text was found.")
            }
            let output = FileWorkspace.unique(for: input, extension: "txt", directory: options.outputDirectory)
            try Data(fullText.utf8).write(to: output, options: .withoutOverwriting)
            return [output]
        }
        
        guard unindexedPageCount > 0 else {
            throw FileveroError.invalidInput("Every page already has selectable text.")
        }
        
        let output = FileWorkspace.unique(
            for: input,
            extension: "pdf",
            suffix: " - Searchable",
            directory: options.outputDirectory
        )
        try writeSearchablePDF(
            pages,
            recognized: recognizedLines,
            attributes: pages.first?.documentAttributes,
            to: output,
            token: token
        )
        return [output]
    }

    struct RecognizedLine {
        let text: String
        let box: CGRect
    }

    public static func text(in image: CGImage) throws -> String {
        let available = Set(try availableLanguages())
        let languages = defaultLanguages.filter(available.contains)
        return try recognize(image, languages: languages.isEmpty ? ["en-US"] : languages)
            .map(\.text)
            .joined(separator: "\n")
    }

    struct RenderablePage {
        let size: CGSize
        let existingText: String?
        let documentAttributes: [AnyHashable: Any]?
        let drawClosure: (CGContext) -> Void

        func render() throws -> CGImage {
            let scale = min(renderDPI / 72.0, maxRenderPixels / max(size.width, size.height))
            let width = max(1, Int((size.width * scale).rounded()))
            let height = max(1, Int((size.height * scale).rounded()))
            
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw FileveroError.failed("A page is too large to recognize.")
            }
            
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            drawClosure(context)
            
            guard let rendered = context.makeImage() else {
                throw FileveroError.failed("A page could not be prepared for recognition.")
            }
            return rendered
        }
    }

    private static func extractPDFPages(_ input: URL, password: String) throws -> [RenderablePage] {
        let source = try PDFEngine.open(input, password: password)
        guard !source.isEncrypted else {
            throw FileveroError.unsupported(
                "This PDF is password-protected. A searchable copy would not keep that protection, so it was not changed."
            )
        }
        
        var pages: [RenderablePage] = []
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index), let reference = page.pageRef else {
                throw FileveroError.failed("A PDF page could not be read.")
            }
            if page.annotations.contains(where: { $0.widgetFieldType == .signature }) {
                throw FileveroError.unsupported(
                    "This PDF is signed. Adding a text layer would invalidate its signature, so it was not changed."
                )
            }
            
            let bounds = page.bounds(for: .cropBox)
            let rotatedSize = abs(page.rotation) % 180 == 90
                ? CGSize(width: bounds.height, height: bounds.width)
                : bounds.size
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isSearchable = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count >= minimumExistingCharacterCount
            
            pages.append(
                RenderablePage(
                    size: rotatedSize,
                    existingText: isSearchable ? text : nil,
                    documentAttributes: source.documentAttributes
                ) { context in
                    context.saveGState()
                    context.concatenate(
                        reference.getDrawingTransform(
                            .cropBox,
                            rect: CGRect(origin: .zero, size: rotatedSize),
                            rotate: Int32(page.rotation) - reference.rotationAngle,
                            preserveAspectRatio: true
                        )
                    )
                    context.clip(to: bounds)
                    context.drawPDFPage(reference)
                    for annotation in page.annotations {
                        annotation.draw(with: .cropBox, in: context)
                    }
                    context.restoreGState()
                }
            )
        }
        guard !pages.isEmpty else {
            throw FileveroError.invalidInput("The PDF has no pages.")
        }
        return pages
    }

    private static func extractImagePage(_ input: URL) throws -> RenderablePage {
        let image = try ImageEngine.load(input)
        let sourceProps = CGImageSourceCreateWithURL(input as CFURL, nil).flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let dpi = (sourceProps?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72.0
        let displaySize = CGSize(width: Double(image.width) * 72.0 / dpi, height: Double(image.height) * 72.0 / dpi)
        
        return RenderablePage(size: displaySize, existingText: nil, documentAttributes: nil) { context in
            context.draw(image, in: CGRect(origin: .zero, size: displaySize))
        }
    }

    private static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first?.string, !candidate.isEmpty else { return nil }
            return RecognizedLine(text: candidate, box: observation.boundingBox)
        }.sorted {
            abs($0.box.midY - $1.box.midY) > min($0.box.height, $1.box.height) / 2.0
                ? $0.box.midY > $1.box.midY
                : $0.box.minX < $1.box.minX
        }
    }

    private static func writeSearchablePDF(
        _ pages: [RenderablePage],
        recognized: [[RecognizedLine]],
        attributes: [AnyHashable: Any]?,
        to output: URL,
        token: CancellationToken
    ) throws {
        let outputData = NSMutableData()
        guard let dataConsumer = CGDataConsumer(data: outputData),
              let pdfContext = CGContext(consumer: dataConsumer, mediaBox: nil, nil)
        else {
            throw FileveroError.failed("The searchable PDF could not be created.")
        }
        
        for (page, lines) in zip(pages, recognized) {
            try token.check()
            var pageMediaBox = CGRect(origin: .zero, size: page.size)
            pdfContext.beginPDFPage(
                [kCGPDFContextMediaBox: Data(bytes: &pageMediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            )
            page.drawClosure(pdfContext)
            for line in lines {
                embedInvisibleTextLine(line, in: pageMediaBox, context: pdfContext)
            }
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        
        guard let searchableDoc = PDFDocument(data: outputData as Data), searchableDoc.pageCount == pages.count else {
            throw FileveroError.failed("The searchable PDF could not be verified.")
        }
        if let docAttrs = attributes {
            searchableDoc.documentAttributes = docAttrs
        }
        guard searchableDoc.write(to: output) else {
            throw FileveroError.failed("The searchable PDF could not be saved.")
        }
    }

    private static func embedInvisibleTextLine(_ line: RecognizedLine, in pageBounds: CGRect, context: CGContext) {
        let targetRect = CGRect(
            x: line.box.minX * pageBounds.width,
            y: line.box.minY * pageBounds.height,
            width: line.box.width * pageBounds.width,
            height: line.box.height * pageBounds.height
        )
        guard targetRect.width > 0, targetRect.height > 0 else { return }
        
        let fontRef = CTFontCreateWithName("Helvetica" as CFString, targetRect.height * 0.8, nil)
        let ctLine = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: line.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): fontRef]
            )
        )
        let typographicWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard typographicWidth > 0 else { return }
        
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: targetRect.minX, y: targetRect.minY + targetRect.height * 0.2)
        context.scaleBy(x: targetRect.width / typographicWidth, y: 1.0)
        context.textPosition = .zero
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}

public typealias TextRecognitionEngine = VisionTextRecognizer

