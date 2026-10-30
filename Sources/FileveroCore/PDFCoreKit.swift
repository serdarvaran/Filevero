import AppKit
import Foundation
import PDFKit

/// Native PDF processing and document assembly pipeline.
/// Provides unlocking, raster rendering, page organization, compression, and metadata sanitization.
public enum PDFCoreKit {

    public static func open(_ input: URL, password: String = "") throws -> PDFDocument {
        guard let pdf = PDFDocument(url: input) else {
            throw FileveroError.invalidInput("This PDF could not be opened.")
        }
        if pdf.isLocked && !pdf.unlock(withPassword: password) {
            throw FileveroError.invalidInput("This PDF is password protected. Enter its password.")
        }
        guard pdf.pageCount > 0 else { throw FileveroError.invalidInput("The PDF contains no pages.") }
        return pdf
    }

    public static func create(
        inputs: [URL],
        options: OperationOptions,
        token: CancellationToken,
        progress: ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard let first = inputs.first else { throw FileveroError.invalidInput("Choose images to create a PDF.") }
        let pdf = PDFDocument()

        for (index, input) in inputs.enumerated() {
            progress(Double(index) / Double(inputs.count), "Adding image \(index+1) of \(inputs.count)…")
            try token.check()
            let cgImage = try RasterPipeline.load(input)
            if let page = PDFPage(
                image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            {
                pdf.insert(page, at: pdf.pageCount)
            }
        }

        let output = OutputFiles.unique(for: first, extension: "pdf", directory: options.outputDirectory)
        progress(OperationProgress.indeterminate, "Writing PDF…")
        guard pdf.write(to: output) else { throw FileveroError.failed("Could not create PDF.") }
        return [output]
    }

    public static func render(
        _ input: URL,
        to format: String,
        options: OperationOptions,
        token: CancellationToken,
        progress: ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        let pdf = try open(input, password: options.password)
        let folder = OutputFiles.unique(
            for: input, extension: "", suffix: " - Pages", directory: options.outputDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []

        do {
            for index in 0..<pdf.pageCount {
                try token.check()
                guard let page = pdf.page(at: index) else {
                    throw FileveroError.failed("A PDF page could not be read.")
                }
                let image = try rasterImage(page, dpi: Double(max(36, min(1200, options.dpi))))
                try token.check()
                let output = folder.appendingPathComponent(String(format: "Page %03d.%@", index + 1, format))
                try RasterPipeline.write(image, to: output, quality: options.quality)
                outputs.append(output)
                progress(Double(index + 1) / Double(pdf.pageCount), "Rendered page \(index+1) of \(pdf.pageCount)")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return outputs
    }

    /// Renders the page as viewers show it: its crop box, upright, with annotations.
    static func rasterImage(_ page: PDFPage, dpi: Double) throws -> CGImage {
        guard let ref = page.pageRef else { throw FileveroError.failed("A PDF page could not be read.") }
        let bounds = OfficeDocumentBridge.visualBounds(page)
        let scale = dpi / 72
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        guard scaledWidth.isFinite, scaledHeight.isFinite, scaledWidth > 0, scaledHeight > 0,
            scaledWidth <= 32000, scaledHeight <= 32000
        else { throw FileveroError.failed("PDF page is too large to render at this DPI.") }
        let w = max(1, Int(scaledWidth.rounded()))
        let h = max(1, Int(scaledHeight.rounded()))
        guard w <= 32000, h <= 32000,
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FileveroError.failed("PDF page is too large to render at this DPI.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(
            ref.getDrawingTransform(
                .cropBox, rect: bounds, rotate: Int32(page.rotation) - ref.rotationAngle,
                preserveAspectRatio: true))
        context.drawPDFPage(ref)
        for annotation in page.annotations { annotation.draw(with: .cropBox, in: context) }
        guard let image = context.makeImage() else {
            throw FileveroError.failed("A PDF page could not be rendered.")
        }
        return image
    }

    public static func pageOrder(_ ranges: String, count: Int) throws -> [Int] {
        if ranges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<count) }
        var result: [Int] = []
        for part in ranges.split(separator: ",") {
            let pieces = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 1, let n = Int(pieces[0]), n > 0, n <= count {
                result.append(n - 1)
            } else if pieces.count == 2, pieces != ["", ""],
                let a = pieces[0].isEmpty ? 1 : Int(pieces[0]), let b = pieces[1].isEmpty ? count : Int(pieces[1]),
                a > 0, b > 0, a <= count, b <= count
            {
                result += stride(from: a, through: b, by: a <= b ? 1 : -1).map { $0 - 1 }
            } else {
                throw FileveroError.invalidInput("Invalid page range: \(part). Use numbers between 1 and \(count).")
            }
        }
        guard !result.isEmpty else { throw FileveroError.invalidInput("Select at least one page.") }
        return result
    }

    public static func tool(
        _ kind: ToolKind,
        inputs: [URL],
        options: OperationOptions,
        token: CancellationToken,
        progress: ProgressHandler = { _, _ in }
    ) throws -> [URL] {
        guard let first = inputs.first else { throw FileveroError.invalidInput("Choose PDF files.") }
        if kind == .mergePDF {
            let selections = try inputs.map { input -> [Int] in
                try token.check()
                let pdf = try open(input, password: options.password)
                try requireUnencrypted(pdf)
                return Array(0..<pdf.pageCount)
            }
            let bytes = try PDFStructuralPreservationCodec.transform(inputs, selections: selections, token: token)
            let output = OutputFiles.unique(
                for: first, extension: "pdf", suffix: " - Merged", directory: options.outputDirectory)
            try bytes.write(to: output, options: .atomic)
            return [output]
        }

        var outputs: [URL] = []
        for input in inputs {
            let pdf = try open(input, password: options.password)
            // Compression checks later: PDFKit keeps the source encryption when it rewrites a text PDF.
            if kind != .compress { try requireUnencrypted(pdf) }
            switch kind {
            case .splitPDF:
                let order = try pageOrder(options.pageRanges, count: pdf.pageCount)
                let chunk = max(1, options.pagesPerFile)
                let folder = OutputFiles.unique(
                    for: input, extension: "", suffix: " - Pages", directory: options.outputDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for start in stride(from: 0, to: order.count, by: chunk) {
                    try token.check()
                    let selection = Array(order[start..<min(start + chunk, order.count)])
                    let bytes = try PDFStructuralPreservationCodec.transform(
                        [input], selections: [selection], token: token)
                    // Named after the source pages; a repeated selection gets a numbered name instead of overwriting.
                    let name = String(format: "Pages %03d-%03d", selection[0] + 1, selection[selection.count - 1] + 1)
                    let output = OutputFiles.unique(
                        for: folder.appendingPathComponent(name), extension: "pdf", directory: folder)
                    try bytes.write(to: output, options: .atomic)
                    outputs.append(output)
                    progress(
                        Double(min(start + chunk, order.count)) / Double(order.count),
                        "Saved \(min(start+chunk,order.count)) of \(order.count) pages")
                }
            case .organizePDF:
                let order =
                    options.pdfPageOrder.isEmpty
                    ? try pageOrder(options.pageRanges, count: pdf.pageCount) : options.pdfPageOrder
                var rotations: [Int: Int] = [:]
                for (index, n) in order.enumerated() {
                    try token.check()
                    guard n >= 0, n < pdf.pageCount, let page = pdf.page(at: n) else {
                        throw FileveroError.invalidInput("A page index is outside the PDF.")
                    }
                    rotations[index] =
                        options.pdfPageRotations[index] ?? ((page.rotation % 360) + (options.rotation % 360)) % 360
                }
                let bytes = try PDFStructuralPreservationCodec.transform(
                    [input], selections: [order], rotations: rotations, token: token)
                let output = OutputFiles.unique(
                    for: input, extension: "pdf", suffix: " - Organized", directory: options.outputDirectory)
                if options.pdfUniformWidth {
                    guard !requiresPreservingWrite(pdf) else {
                        throw FileveroError.unsupported(
                            "Uniform page width cannot safely preserve this PDF's form fields, attachments, links or other document features. Turn off Uniform width and try again. No copy was exported."
                        )
                    }
                    guard let organized = PDFDocument(data: bytes),
                        try uniformWidth(organized, token: token).write(to: output)
                    else { throw FileveroError.failed("Could not organize PDF.") }
                } else {
                    try bytes.write(to: output, options: .atomic)
                }
                outputs.append(output)
            case .removeMetadata:
                let cleaned = try withoutSourceMetadata(
                    pdf, clearAnnotationMetadata: options.metadataRemoveAll || options.metadata.isEmpty, token: token)
                cleaned.documentAttributes =
                    options.metadataRemoveAll
                    ? [:]
                    : Dictionary(uniqueKeysWithValues: options.metadata.map { (AnyHashable($0.key), $0.value as Any) })
                let output = OutputFiles.unique(
                    for: input, extension: "pdf", suffix: " - Clean", directory: options.outputDirectory)
                guard cleaned.write(to: output) else { throw FileveroError.failed("Could not save PDF.") }
                outputs.append(output)
            case .compress:
                let output = OutputFiles.unique(
                    for: input, extension: "pdf", suffix: " - Compressed", directory: options.outputDirectory)
                let original = Int64((try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                if let bytes = options.targetBytes, bytes <= 0 {
                    throw FileveroError.invalidInput("Target file size must be positive.")
                }
                if let percent = options.percentage, !percent.isFinite || percent <= 0 || percent >= 100 {
                    throw FileveroError.invalidInput("Percentage reduction must be between 0 and 100.")
                }
                let target = options.targetBytes ?? options.percentage.map { Int64(Double(original) * (1 - $0 / 100)) }
                if !(pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || requiresPreservingWrite(pdf)
                {
                    try token.check()
                    var settings: [PDFDocumentWriteOption: Any] = [:]
                    if #available(macOS 13.4, *) {
                        settings = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
                    }
                    guard pdf.write(to: output, withOptions: settings) else {
                        throw FileveroError.failed("Could not compress PDF.")
                    }
                    let bytes = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    if let target, bytes > target {
                        try? FileManager.default.removeItem(at: output)
                        throw FileveroError.failed(
                            "That PDF size cannot be reached while keeping selectable text, links, and annotations. Choose a larger target."
                        )
                    }
                    try OutputFiles.retainSmallerOriginal(input, output: output, target: target)
                    outputs.append(output)
                    continue
                }
                try requireUnencrypted(pdf)
                var dpi = 144.0
                var quality = options.quality
                var complete = false
                for attempt in 0..<14 {
                    try token.check()
                    let compressed = PDFDocument()
                    for n in 0..<pdf.pageCount {
                        try token.check()
                        progress(
                            Double(n) / Double(pdf.pageCount),
                            "Compressing PDF · attempt \(attempt+1) · page \(n+1) of \(pdf.pageCount)")
                        guard let page = pdf.page(at: n) else {
                            throw FileveroError.failed("PDF page \(n + 1) could not be read.")
                        }
                        let bitmap = NSBitmapImageRep(cgImage: try rasterImage(page, dpi: dpi))
                        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                            let thumbnail = NSImage(data: data)
                        else { throw FileveroError.failed("PDF page \(n + 1) could not be compressed.") }
                        // PDFPage sizes itself from the image's point size, which would otherwise be its pixel size.
                        thumbnail.size = OfficeDocumentBridge.visualBounds(page).size
                        guard let result = PDFPage(image: thumbnail) else {
                            throw FileveroError.failed("PDF page \(n + 1) could not be compressed.")
                        }
                        compressed.insert(result, at: compressed.pageCount)
                    }
                    guard compressed.write(to: output) else { throw FileveroError.failed("Could not compress PDF.") }
                    let bytes =
                        (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value
                        ?? 0
                    if target == nil || bytes <= target! {
                        complete = true
                        break
                    }
                    dpi = max(36, dpi * 0.8)
                    quality = max(0.05, quality * 0.75)
                }
                guard complete else {
                    try? FileManager.default.removeItem(at: output)
                    throw FileveroError.failed("The requested PDF size could not be reached.")
                }
                try OutputFiles.retainSmallerOriginal(input, output: output, target: target)
                outputs.append(output)
            default:
                throw FileveroError.unsupported("Unsupported PDF tool.")
            }
        }
        return outputs
    }

    /// Rebuilt copies cannot keep the source's encryption, so they would silently drop its password.
    static func requireUnencrypted(_ pdf: PDFDocument) throws {
        guard !pdf.isEncrypted else {
            throw FileveroError.unsupported(
                "This PDF is password-protected. Remove the password first; the new copy would not keep it.")
        }
    }

    private static func requiresPreservingWrite(_ document: PDFDocument) -> Bool {
        if document.outlineRoot != nil
            || (0..<document.pageCount).contains(where: { !(document.page(at: $0)?.annotations.isEmpty ?? true) })
        {
            return true
        }
        guard let catalog = document.documentRef?.catalog else { return false }
        for key in [
            "AcroForm", "Names", "AF", "Collection", "OCProperties", "StructTreeRoot", "MarkInfo", "Dests",
            "PageLabels", "OpenAction", "AA", "Perms", "Metadata",
        ] {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &object) { return true }
        }
        return (0..<document.pageCount).contains { index in
            guard let dictionary = document.page(at: index)?.pageRef?.dictionary else { return false }
            var object: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, "AF", &object)
        }
    }

    private static func withoutSourceMetadata(
        _ source: PDFDocument,
        clearAnnotationMetadata: Bool,
        token: CancellationToken
    ) throws -> PDFDocument {
        let catalog = source.documentRef?.catalog
        func hasKey(_ dictionary: CGPDFDictionaryRef?, _ key: String) -> Bool {
            guard let dictionary else { return false }
            var object: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, key, &object)
        }
        var names: CGPDFDictionaryRef?
        if let catalog { _ = CGPDFDictionaryGetDictionary(catalog, "Names", &names) }
        let pages = (0..<source.pageCount).compactMap { source.page(at: $0) }
        let feature: String?
        if hasKey(catalog, "AcroForm")
            || pages.contains(where: { $0.annotations.contains(where: { $0.type == "Widget" }) })
        {
            feature = "form fields"
        } else if hasKey(names, "EmbeddedFiles") || hasKey(catalog, "AF") || hasKey(catalog, "Collection")
            || pages.contains(where: { hasKey($0.pageRef?.dictionary, "AF") })
        {
            feature = "embedded files"
        } else if hasKey(catalog, "OCProperties") {
            feature = "optional content layers"
        } else if hasKey(catalog, "StructTreeRoot") {
            feature = "accessibility tags"
        } else {
            feature = nil
        }
        if let feature {
            throw FileveroError.unsupported(
                "This PDF contains \(feature). Metadata cleanup cannot safely preserve those features. No copy was exported."
            )
        }
        let result = PDFDocument()
        for index in 0..<source.pageCount {
            try token.check()
            guard let page = source.page(at: index)?.copy() as? PDFPage else {
                throw FileveroError.failed("A PDF page could not be copied.")
            }
            for annotation in page.annotations {
                if clearAnnotationMetadata {
                    if annotation.type != "Widget" { annotation.userName = nil }
                    annotation.modificationDate = nil
                    annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/CreationDate"))
                }
            }
            result.insert(page, at: result.pageCount)
        }
        try copyNavigation(from: source, to: result, token: token)
        return result
    }

    /// Points internal links and bookmarks at `result`, whose pages are copies of `source`'s pages at the same indexes.
    static func copyNavigation(from source: PDFDocument, to result: PDFDocument, token: CancellationToken) throws {
        for index in 0..<result.pageCount {
            let originals = source.page(at: index)?.annotations ?? []
            for annotation in result.page(at: index)?.annotations ?? [] {
                guard let action = annotation.action as? PDFActionGoTo else { continue }
                // A copied /Dest link can lose its target page; the source link in the same place still has it.
                let target =
                    action.destination.page != nil
                    ? action.destination
                    : (originals.first { $0.bounds == annotation.bounds }?.action as? PDFActionGoTo)?.destination
                if let target, let mapped = mappedDestination(target, from: source, to: result) {
                    annotation.action = PDFActionGoTo(destination: mapped)
                }
            }
        }
        try copyOutline(from: source, to: result, token: token)
    }

    /// The same point on the page at the same index in `result`. `pageTransforms` maps each source page's space
    /// onto a redrawn result page; without it the pages share coordinates.
    static func mappedDestination(
        _ original: PDFDestination, from source: PDFDocument, to result: PDFDocument,
        pageTransforms: [CGAffineTransform]? = nil
    ) -> PDFDestination? {
        guard let page = original.page else { return nil }
        let index = source.index(for: page)
        guard index < result.pageCount, let copy = result.page(at: index) else { return nil }
        var point = original.point
        if let pageTransforms, pageTransforms.indices.contains(index) {
            point = mappedPoint(point, on: page, by: pageTransforms[index])
        }
        let mapped = PDFDestination(page: copy, at: point)
        mapped.zoom = original.zoom
        return mapped
    }

    /// An unspecified coordinate (keep the viewer's position on that axis) stays unspecified on whichever axis
    /// it lands on after rotation.
    static func mappedPoint(_ point: CGPoint, on page: PDFPage, by transform: CGAffineTransform) -> CGPoint {
        let unspecified = kPDFDestinationUnspecifiedValue
        let crop = page.bounds(for: .cropBox)
        let isXUnspecified = point.x == unspecified
        let isYUnspecified = point.y == unspecified
        let known = CGPoint(x: isXUnspecified ? crop.minX : point.x, y: isYUnspecified ? crop.maxY : point.y)
        var mapped = known.applying(transform)
        let isAxisSwapped = abs(transform.a) < abs(transform.c)
        if isAxisSwapped ? isYUnspecified : isXUnspecified { mapped.x = unspecified }
        if isAxisSwapped ? isXUnspecified : isYUnspecified { mapped.y = unspecified }
        return mapped
    }

    static func copyOutline(
        from source: PDFDocument, to result: PDFDocument, pageTransforms: [CGAffineTransform]? = nil,
        token: CancellationToken
    ) throws {
        var visited = Set<ObjectIdentifier>()
        func outline(_ original: PDFOutline, depth: Int) throws -> PDFOutline {
            try token.check()
            guard depth < 512, visited.insert(ObjectIdentifier(original)).inserted else {
                throw FileveroError.invalidInput("The PDF has an invalid bookmark tree.")
            }
            let copy = PDFOutline()
            copy.label = original.label
            if let originalDestination = original.destination,
                let mapped = mappedDestination(
                    originalDestination, from: source, to: result, pageTransforms: pageTransforms)
            {
                copy.destination = mapped
            } else {
                copy.action = original.action?.copy() as? PDFAction
            }
            for index in 0..<original.numberOfChildren {
                if let child = original.child(at: index) {
                    copy.insertChild(try outline(child, depth: depth + 1), at: copy.numberOfChildren)
                }
            }
            copy.isOpen = original.isOpen
            return copy
        }
        if let root = source.outlineRoot { result.outlineRoot = try outline(root, depth: 0) }
    }

    public static func uniformWidth(_ document: PDFDocument, token: CancellationToken = .init()) throws -> PDFDocument {
        let pages = try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index), let reference = page.pageRef else {
                throw FileveroError.failed("A PDF page could not be read.")
            }
            return (page, reference)
        }
        func displayedSize(_ page: PDFPage) -> CGSize {
            let b = page.bounds(for: .cropBox)
            return abs(page.rotation) % 180 == 90 ? CGSize(width: b.height, height: b.width) : b.size
        }
        guard let narrowest = pages.map({ displayedSize($0.0).width }).min(), narrowest > 0 else {
            throw FileveroError.invalidInput("The PDF has no valid page sizes.")
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw FileveroError.failed("Could not scale PDF pages.") }
        for (page, ref) in pages {
            try token.check()
            let size = displayedSize(page)
            let scale = narrowest / size.width
            var box = CGRect(x: 0, y: 0, width: narrowest, height: size.height * scale)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            let rotation = Int32(page.rotation) - Int32(ref.rotationAngle)
            let transform = ref.getDrawingTransform(.cropBox, rect: box, rotate: rotation, preserveAspectRatio: true)
            context.concatenate(transform)
            context.drawPDFPage(ref)
            for annotation in page.annotations { annotation.draw(with: .cropBox, in: context) }
            context.endPDFPage()
        }
        context.closePDF()
        guard let output = PDFDocument(data: data as Data) else {
            throw FileveroError.failed("Could not build scaled PDF.")
        }
        output.documentAttributes = document.documentAttributes
        return output
    }
}

// MARK: - Compatibility Bridge
public typealias PDFEngine = PDFCoreKit

