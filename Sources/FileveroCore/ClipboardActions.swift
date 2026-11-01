import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One-step changes offered for a clipboard history item: text rewrites, a QR code, or saving an image as a file.
public enum ClipboardAction: String, CaseIterable, Sendable {
    case uppercase, lowercase, titleCase, tidyWhitespace, formatJSON, qrCode, savePNG, saveJPG

    public var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .tidyWhitespace: return "Tidy Whitespace"
        case .formatJSON: return "Format JSON"
        case .qrCode: return "Copy as QR Code"
        case .savePNG: return "Save as PNG"
        case .saveJPG: return "Save as JPG"
        }
    }

    public static func available(for kind: ClipboardKind) -> [ClipboardAction] {
        switch kind {
        case .text, .richText: return [.uppercase, .lowercase, .titleCase, .tidyWhitespace, .formatJSON, .qrCode]
        case .link: return [.qrCode]
        case .image: return [.savePNG, .saveJPG]
        case .file: return []
        }
    }

    /// The rewritten text, or nil when this action does not rewrite text or the text cannot be rewritten (invalid JSON).
    /// Case changes use the interface language, so Turkish turns "i" into "İ".
    public func transform(_ text: String, language: String) -> String? {
        let locale = Locale(identifier: language)
        switch self {
        case .uppercase: return text.uppercased(with: locale)
        case .lowercase: return text.lowercased(with: locale)
        case .titleCase: return Self.titleCased(text, locale: locale)
        case .tidyWhitespace: return Self.tidied(text)
        case .formatJSON: return Self.indentedJSON(text)
        case .qrCode, .savePNG, .saveJPG: return nil
        }
    }

    private static func titleCased(_ text: String, locale: Locale) -> String {
        var result = ""
        var startsWord = true
        for character in text {
            let piece = String(character)
            result += startsWord ? piece.uppercased(with: locale) : piece.lowercased(with: locale)
            startsWord = character.isWhitespace
        }
        return result
    }

    private static func tidied(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var trimmed = String(line)
            while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Re-indents the text itself rather than re-encoding parsed values, so key order, numbers and escapes stay as copied.
    private static func indentedJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }
        // Unicode scalars, not Characters: a combining mark right after a quote would otherwise hide the quote.
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0
        func append(_ text: String) { output.append(contentsOf: text.unicodeScalars) }
        func newline() { append("\n" + String(repeating: "  ", count: depth)) }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inString {
                output.append(scalar)
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                output.append(scalar)
            case "{", "[":
                let closing: Unicode.Scalar = scalar == "{" ? "}" : "]"
                var next = index
                while next < scalars.count, scalars[next].properties.isWhitespace { next += 1 }
                if next < scalars.count, scalars[next] == closing {
                    output.append(scalar)
                    output.append(closing)
                    index = next + 1
                } else {
                    output.append(scalar)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                output.append(scalar)
            case ",":
                output.append(scalar)
                newline()
            case ":":
                append(": ")
            default:
                if !scalar.properties.isWhitespace { output.append(scalar) }
            }
        }
        return String(output)
    }

    /// A crisp QR code image of the text, or nil when the text is too long for a QR code.
    public static func qrCodePNG(for text: String, size: Int = 512) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = max(1, (CGFloat(size) / code.extent.width).rounded(.down))
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Writes a copied image to a new file; an existing file with the same name is never replaced.
public enum ClipboardImageExport {
    public static func save(_ png: Data?, as format: String, in folder: URL, date: Date = Date()) throws -> URL {
        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FileveroError.invalidInput("This clipboard item has no image to save.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        // The extension is part of the name passed in, so the seconds in "14.30.15" are not taken for one.
        let name = folder.appendingPathComponent("Clipboard Image \(formatter.string(from: date)).\(format)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = OutputFiles.unique(for: name, extension: format, directory: folder)
        try ImageEngine.write(image, to: output, quality: 0.9)
        return output
    }
}
