import CoreText
import Foundation
import PDFKit

/// High-throughput batch processing for PDF assets.
/// Provides watermarking, dynamic pagination stamps, password encryption/decryption,
/// and heterogeneous file-to-PDF concatenation.
public enum PDFBatchProcessor {

    public static func run(
        _ kind: ToolKind,
        inputs: [URL],
        options: OperationOptions,
        token: CancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> [URL] {
        if kind == .combineToPDF {
            return [try combine(inputs, options: options, token: token, progress: progress)]
        }

        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            try token.check()
            progress(Double(index) / Double(inputs.count), input.lastPathComponent)
            switch kind {
            case .watermark:
                let settings = options.watermark ?? .init()
                outputs.append(
                    try stamp(input, suffix: " - Watermarked", options: options, token: token) {
                        _, _, context, bounds in
                        try RasterBatchProcessor.drawWatermark(settings, in: context, bounds: bounds)
                    })
            case .pageNumbers:
                let settings = options.pageNumbers ?? .init()
                guard settings.fontSize.isFinite, (4...72).contains(settings.fontSize), settings.startNumber >= 0 else {
                    throw FileveroError.invalidInput(
                        "Choose a text size between 4 and 72 and a start number of 0 or more.")
                }
                outputs.append(
                    try stamp(input, suffix: " - Numbered", options: options, token: token) {
                        page, count, context, bounds in
                        drawNumber(
                            settings.label(page: page, count: count), settings: settings, in: context, bounds: bounds)
                    })
            case .protectPDF:
                outputs.append(try protect(input, options: options))
            case .unlockPDF:
                outputs.append(try unlock(input, options: options, token: token))
            default:
                throw FileveroError.unsupported("\(kind.title) is not a PDF operation.")
            }
        }
        return outputs
    }

    /// Redraws each page with the stamp on top. Annotations become part of the page.
    private static func stamp(
        _ input: URL,
        suffix: String,
        options: OperationOptions,
        token: CancellationToken,
        draw: (Int, Int, CGContext, CGRect) throws -> Void
    ) throws -> URL {
        let source = try PDFCoreKit.open(input, password: options.password)
        try requireRewritable(source)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw FileveroError.failed("The PDF could not be created.") }

        var pageTransforms: [CGAffineTransform] = []
        for index in 0..<source.pageCount {
            try token.check()
            guard let page = source.page(at: index), let reference = page.pageRef else {
                throw FileveroError.failed("A PDF page could not be read.")
            }
            let bounds = page.bounds(for: .cropBox)
            let size = abs(page.rotation) % 180 == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            var box = CGRect(origin: .zero, size: size)
            context.beginPDFPage(
                [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            let transform = reference.getDrawingTransform(
                .cropBox, rect: box, rotate: Int32(page.rotation) - reference.rotationAngle, preserveAspectRatio: true)
            pageTransforms.append(transform)
            context.saveGState()
            context.concatenate(transform)
            context.clip(to: bounds)
            context.drawPDFPage(reference)
            for annotation in page.annotations where !annotation.isKind(.link) {
                annotation.draw(with: .cropBox, in: context)
            }
            context.restoreGState()
            try draw(index, source.pageCount, context, box)
            context.endPDFPage()
        }
        context.closePDF()

        guard let drawn = PDFDocument(data: data as Data), drawn.pageCount == source.pageCount else {
            throw FileveroError.failed("The PDF could not be verified.")
        }
        // PDFKit does not save an outline set on a document opened from data, so the pages move to a new one.
        let result = PDFDocument()
        for index in 0..<drawn.pageCount {
            guard let page = drawn.page(at: index) else { throw FileveroError.failed("The PDF could not be verified.") }
            result.insert(page, at: index)
        }
        try carryOver(from: source, to: result, pageTransforms: pageTransforms, token: token)
        let output = OutputFiles.unique(
            for: input, extension: "pdf", suffix: suffix, directory: options.outputDirectory)
        guard result.write(to: output) else { throw FileveroError.failed("The PDF could not be saved.") }
        return output
    }

    private static func requireRewritable(_ pdf: PDFDocument) throws {
        try PDFCoreKit.requireUnencrypted(pdf)
        try requireNoFormsOrSignatures(pdf)
    }

    private static func requireNoFormsOrSignatures(_ pdf: PDFDocument) throws {
        let pages = (0..<pdf.pageCount).compactMap(pdf.page)
        if pages.contains(where: { $0.annotations.contains { $0.widgetFieldType == .signature } }) {
            throw FileveroError.unsupported(
                "This PDF is signed. Changing its pages would invalidate the signature, so it was not changed.")
        }
        if pages.contains(where: { $0.annotations.contains { $0.isKind(.widget) } }) {
            throw FileveroError.unsupported(
                "This PDF has form fields, which would stop working in the new copy, so it was not changed.")
        }
    }

    /// `pageTransforms` maps each source page's space (crop box offset, rotation) onto its redrawn page, for link
    /// bounds and for link and bookmark destinations.
    private static func carryOver(
        from source: PDFDocument, to result: PDFDocument, pageTransforms: [CGAffineTransform], token: CancellationToken
    ) throws {
        if let attributes = source.documentAttributes { result.documentAttributes = attributes }
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index), let target = result.page(at: index) else { continue }
            for link in page.annotations where link.isKind(.link) {
                let copy = PDFAnnotation(
                    bounds: link.bounds.applying(pageTransforms[index]), forType: .link, withProperties: nil)
                if let url = link.url ?? (link.action as? PDFActionURL)?.url {
                    copy.url = url
                } else if let action = link.action as? PDFActionGoTo,
                    let destination = PDFCoreKit.mappedDestination(
                        action.destination, from: source, to: result, pageTransforms: pageTransforms)
                {
                    copy.action = PDFActionGoTo(destination: destination)
                } else {
                    continue
                }
                target.addAnnotation(copy)
            }
        }
        try PDFCoreKit.copyOutline(from: source, to: result, pageTransforms: pageTransforms, token: token)
    }

    private static func drawNumber(_ label: String, settings: PageNumberOptions, in context: CGContext, bounds: CGRect) {
        let font = CTFontCreateUIFontForLanguage(.system, settings.fontSize, nil) as Any
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: label,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1),
                ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let margin = max(18, settings.fontSize * 2)
        let x: CGFloat
        switch settings.position {
        case .bottomCenter: x = bounds.midX - width / 2
        case .bottomLeft: x = bounds.minX + margin
        case .bottomRight, .topRight: x = bounds.maxX - margin - width
        }
        let y = settings.position == .topRight ? bounds.maxY - margin : bounds.minY + margin - settings.fontSize / 2
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func protect(_ input: URL, options: OperationOptions) throws -> URL {
        let password = options.password
        guard password.count >= 4 else {
            throw FileveroError.invalidInput("Use a password with at least 4 characters.")
        }
        guard password.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            throw FileveroError.invalidInput("Use only English letters, digits and common symbols in a PDF password.")
        }
        let pdf = try PDFCoreKit.open(input)
        try requireRewritable(pdf)
        let output = OutputFiles.unique(
            for: input, extension: "pdf", suffix: " - Protected", directory: options.outputDirectory)
        guard pdf.write(to: output, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
            throw FileveroError.failed("The protected PDF could not be saved.")
        }
        guard let check = PDFDocument(url: output), check.isEncrypted, check.isLocked,
            check.unlock(withPassword: password)
        else {
            try? FileManager.default.removeItem(at: output)
            throw FileveroError.failed("The password could not be verified, so no copy was saved.")
        }
        return output
    }

    private static func unlock(_ input: URL, options: OperationOptions, token: CancellationToken) throws -> URL {
        guard let pdf = PDFDocument(url: input) else {
            throw FileveroError.invalidInput("This PDF could not be opened.")
        }
        guard pdf.isEncrypted else { throw FileveroError.invalidInput("This PDF has no password.") }
        guard pdf.unlock(withPassword: options.password) else {
            throw FileveroError.invalidInput("The password is not correct.")
        }
        try requireNoFormsOrSignatures(pdf)
        let plain = PDFDocument()
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.copy() as? PDFPage else {
                throw FileveroError.failed("A PDF page could not be read.")
            }
            plain.insert(page, at: index)
        }
        if let attributes = pdf.documentAttributes { plain.documentAttributes = attributes }
        try PDFCoreKit.copyNavigation(from: pdf, to: plain, token: token)
        let output = OutputFiles.unique(
            for: input, extension: "pdf", suffix: " - Unlocked", directory: options.outputDirectory)
        guard plain.write(to: output), let check = PDFDocument(url: output), !check.isEncrypted,
            check.pageCount == pdf.pageCount
        else {
            try? FileManager.default.removeItem(at: output)
            throw FileveroError.failed("The unlocked copy could not be verified, so it was not saved.")
        }
        return output
    }

    public static func canCombine(_ url: URL) -> Bool {
        let category = FileCategory.detect(url)
        if category == .pdf || (category == .image && FeatureCatalog.normalizedExtension(url) != "svg") { return true }
        return FeatureCatalog.allConversions[FeatureCatalog.normalizedExtension(url)]?.contains("pdf") ?? false
    }

    private static func combine(
        _ inputs: [URL],
        options: OperationOptions,
        token: CancellationToken,
        progress: ProgressHandler
    ) throws -> URL {
        guard inputs.count >= 2 else { throw FileveroError.invalidInput("Choose two or more files.") }
        let work = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var parts: [URL] = []
        for (index, input) in inputs.enumerated() {
            try token.check()
            progress(Double(index) / Double(inputs.count) * 0.9, "Preparing \(input.lastPathComponent)…")
            guard canCombine(input) else {
                throw FileveroError.unsupported("\(input.lastPathComponent) cannot be turned into a PDF.")
            }
            let folder = work.appendingPathComponent("\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var settings = options
            settings.outputDirectory = folder
            switch FileCategory.detect(input) {
            case .pdf:
                let copy = folder.appendingPathComponent(input.lastPathComponent)
                try FileManager.default.copyItem(at: input, to: copy)
                parts.append(copy)
            case .image:
                parts += try PDFCoreKit.create(inputs: [input], options: settings, token: token)
            default:
                parts += try DocumentProcessor.convert(input, to: "pdf", options: settings, token: token)
            }
        }
        progress(0.92, "Joining pages…")
        let result = PDFDocument()
        for part in parts {
            guard let pdf = PDFDocument(url: part) else {
                throw FileveroError.failed("\(part.lastPathComponent) could not be opened.")
            }
            if pdf.isLocked, !pdf.unlock(withPassword: options.password) {
                throw FileveroError.invalidInput("\(part.lastPathComponent) is password protected. Enter its password.")
            }
            try requireNoFormsOrSignatures(pdf)
            for index in 0..<pdf.pageCount {
                try token.check()
                guard let page = pdf.page(at: index)?.copy() as? PDFPage else {
                    throw FileveroError.failed("A PDF page could not be read.")
                }
                for link in page.annotations
                where link.isKind(.link) && link.url == nil && (link.action as? PDFActionURL) == nil {
                    page.removeAnnotation(link)
                }
                result.insert(page, at: result.pageCount)
            }
        }
        let output = OutputFiles.unique(
            for: inputs[0], extension: "pdf", suffix: " - Combined", directory: options.outputDirectory)
        guard result.write(to: output) else { throw FileveroError.failed("The combined PDF could not be saved.") }
        return output
    }
}

extension PDFAnnotation {
    fileprivate func isKind(_ subtype: PDFAnnotationSubtype) -> Bool {
        type == String(subtype.rawValue.drop { $0 == "/" })
    }
}

// MARK: - Compatibility Bridge
public typealias PDFBatchTools = PDFBatchProcessor

