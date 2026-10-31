import AppKit
import Foundation
import PDFKit

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Generates descriptive, content-aware file names using on-device Apple Intelligence and local OCR.
/// All analysis is strictly local; original files remain untouched and users review all suggested names in the UI.
public enum ContentNameIntelligence {
    
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    /// Maximum characters extracted from the document to maintain prompt compactness and efficiency.
    static let maximumAnalysisCharacters = 4000
    private static let maximumOutputLength = 80

    public static var availability: Availability {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case .unavailable(.deviceNotEligible):
                    return .unavailable("This Mac does not support Apple Intelligence.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    return .unavailable("Turn on Apple Intelligence in System Settings to get name suggestions.")
                case .unavailable(.modelNotReady):
                    return .unavailable("Apple Intelligence is still getting ready. Try again later.")
                case .unavailable:
                    return .unavailable("Apple Intelligence is not available right now.")
                }
            }
        #endif
        return .unavailable("Name suggestions need macOS 26 or later with Apple Intelligence.")
    }

    public static var status: Availability { availability }

    public static func supports(_ fileURL: URL) -> Bool {
        switch FileCategory.detect(fileURL) {
        case .image, .pdf:
            return true
        case .document:
            return supportedDocumentTypes[FeatureCatalog.normalizedExtension(fileURL)] != nil
        default:
            return false
        }
    }

    public static func suggest(for fileURL: URL) async throws -> String {
        guard supports(fileURL) else {
            throw FileveroError.unsupported("Name suggestions work with images, PDFs and documents.")
        }
        
        let extractedText = try extractContent(from: fileURL)
        let imageAttachmentURL = FileCategory.detect(fileURL) == .image ? fileURL : nil
        
        guard !extractedText.isEmpty || imageAttachmentURL != nil else {
            throw FileveroError.invalidInput("\(fileURL.lastPathComponent) has no readable text.")
        }
        
        #if canImport(FoundationModels)
            if #available(macOS 26, *), case .available = availability {
                let modelOutput = try await requestSuggestedName(text: extractedText, imageURL: imageAttachmentURL)
                guard let sanitized = sanitizeModelOutput(modelOutput) else {
                    throw FileveroError.failed("No usable name was suggested for \(fileURL.lastPathComponent).")
                }
                return sanitized
            }
        #endif
        
        if case .unavailable(let reason) = availability {
            throw FileveroError.unsupported(reason)
        }
        throw FileveroError.unsupported("Apple Intelligence is not available right now.")
    }

    /// Extracts representative text from the document, PDF text stream/OCR, or image recognition.
    public static func content(of fileURL: URL) throws -> String {
        try extractContent(from: fileURL)
    }

    static func extractContent(from fileURL: URL) throws -> String {
        let textContent: String
        
        switch FileCategory.detect(fileURL) {
        case .image:
            textContent = try TextRecognitionEngine.text(in: ImageEngine.load(fileURL))
            
        case .pdf:
            let pdfDocument = try PDFEngine.open(fileURL)
            let pageRange = 0..<min(pdfDocument.pageCount, 3)
            let streamText = pageRange.compactMap { pdfDocument.page(at: $0)?.string }.joined(separator: "\n")
            
            if !streamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textContent = streamText
            } else if let firstPage = pdfDocument.page(at: 0) {
                let cropBounds = firstPage.bounds(for: .cropBox)
                let renderScale = min(2.0, 2000.0 / max(cropBounds.width, cropBounds.height, 1.0))
                let thumbnail = firstPage.thumbnail(
                    of: NSSize(width: cropBounds.width * renderScale, height: cropBounds.height * renderScale),
                    for: .cropBox
                )
                guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw FileveroError.failed("\(fileURL.lastPathComponent) could not be read.")
                }
                textContent = try TextRecognitionEngine.text(in: cgImage)
            } else {
                textContent = ""
            }
            
        default:
            guard let documentType = supportedDocumentTypes[FeatureCatalog.normalizedExtension(fileURL)] else {
                return ""
            }
            textContent = try NSAttributedString(
                url: fileURL,
                options: [.documentType: documentType],
                documentAttributes: nil
            ).string
        }
        
        let cleanedLines = textContent
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            
        return String(cleanedLines.prefix(maximumAnalysisCharacters))
    }

    private static let supportedDocumentTypes: [String: NSAttributedString.DocumentType] = [
        "txt": .plain,
        "md": .plain,
        "markdown": .plain,
        "rtf": .rtf,
        "rtfd": .rtfd,
        "doc": .docFormat,
        "docx": .officeOpenXML,
        "odt": .openDocument
    ]

    /// Sanitizes raw model output into a valid filesystem stem without illegal separators or redundant quotes.
    public static func sanitizeModelOutput(_ raw: String) -> String? {
        var candidate = raw.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            
        candidate = candidate.trimmingCharacters(
            in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’`*_."))
        )
        
        let extensionCheck = (candidate as NSString).pathExtension
        if !extensionCheck.isEmpty, extensionCheck.count <= 5, extensionCheck.allSatisfy(\.isLetter) {
            candidate = (candidate as NSString).deletingPathExtension
        }
        
        candidate = candidate
            .replacingOccurrences(of: "[/:\\\\\\p{Cc}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
            
        if candidate.count > maximumOutputLength {
            candidate = String(candidate.prefix(maximumOutputLength)).trimmingCharacters(in: .whitespaces)
        }
        
        candidate = candidate.precomposedStringWithCanonicalMapping
        return candidate.isEmpty ? nil : candidate
    }

    public static func cleaned(_ raw: String) -> String? {
        sanitizeModelOutput(raw)
    }

    #if canImport(FoundationModels)
        @available(macOS 26, *)
        private static func requestSuggestedName(text: String, imageURL: URL?) async throws -> String {
            let session = LanguageModelSession(
                instructions: """
                    You name files. Suggest one short, descriptive file name for the content you are given, in the same language as its text.
                    Use 2 to 6 words separated by spaces. Include a date, number or name only when it identifies the document.
                    Do not add a file extension, quotes or an explanation.
                    """
            )
            
            // Image prompts need the macOS 27 SDK (Xcode 27); older toolchains name files from their text only.
            #if compiler(>=6.4)
                if #available(macOS 27, *), let imageURL, SystemLanguageModel.default.capabilities.contains(.vision) {
                    return try await session.respond(generating: PromptGeneratedName.self) {
                        "Suggest a file name for this image."
                        if !text.isEmpty { "Text visible in the image:\n\(text)" }
                        Attachment<ImageAttachmentContent>(imageURL: imageURL)
                    }.content.name
                }
            #endif
            
            return try await session.respond(
                to: "Suggest a file name for this content:\n\(text)",
                generating: PromptGeneratedName.self
            ).content.name
        }
    #endif
}

#if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable
    private struct PromptGeneratedName {
        @Guide(description: "A short descriptive file name without extension, 2 to 6 words separated by spaces")
        var name: String
    }
#endif

public typealias FileNameSuggester = ContentNameIntelligence

