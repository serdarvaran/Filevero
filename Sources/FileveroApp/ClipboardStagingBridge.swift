import AppKit
import FileveroCore

/// Ingests clipboard file references, raw raster data, or web media links into the staging shelf.
@MainActor
public enum ClipboardStagingBridge {
    public struct Result: Sendable {
        public var urls: [URL] = []
        public var link: URL?
        public var label: String

        public init(urls: [URL] = [], link: URL? = nil, label: String) {
            self.urls = urls
            self.link = link
            self.label = label
        }
    }

    public static func read(_ pasteboard: NSPasteboard = .general, directory: URL? = nil) throws -> Result {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var uniqueSet = Set<URL>()
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) && uniqueSet.insert($0).inserted }
            guard !existing.isEmpty else { throw ImportError.unavailable }
            return Result(urls: existing, label: "Pasted files")
        }

        let stagingFolder = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Filevero/Imports", isDirectory: true)

        func generateDestination(withExtension ext: String) throws -> URL {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let filename = "Clipboard \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).\(ext)"
            return stagingFolder.appendingPathComponent(filename)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData) {
            guard rep.pixelsWide > 0, rep.pixelsHigh > 0,
                  Int64(rep.pixelsWide) * Int64(rep.pixelsHigh) <= 100_000_000,
                  let pngBytes = rep.representation(using: .png, properties: [:])
            else {
                throw ImportError.imageTooLarge
            }
            let fileURL = try generateDestination(withExtension: "png")
            try pngBytes.write(to: fileURL, options: .atomic)
            return Result(urls: [fileURL], label: "Pasted image")
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ImportError.empty
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let webURL = URL(string: trimmedText),
           ["http", "https"].contains(webURL.scheme?.lowercased() ?? ""),
           webURL.host != nil,
           !trimmedText.contains(where: { $0.isWhitespace }) {
            return Result(link: webURL, label: "Copied link")
        }

        guard text.utf8.count <= 16 * 1024 * 1024 else {
            throw ImportError.textTooLarge
        }

        let textFileURL = try generateDestination(withExtension: "txt")
        try Data(text.utf8).write(to: textFileURL, options: .atomic)
        return Result(urls: [textFileURL], label: "Pasted text")
    }

    public enum ImportError: LocalizedError {
        case empty
        case unavailable
        case imageTooLarge
        case textTooLarge

        public var errorDescription: String? {
            switch self {
            case .empty: return "Copy a file, some text, an image or a public media link first."
            case .unavailable: return "Those files are no longer available."
            case .imageTooLarge: return "This image is too large to paste. Choose the image file instead."
            case .textTooLarge: return "This text is too large to paste. Choose a text file instead."
            }
        }
    }
}

// Backward-compatibility alias
public typealias ClipboardImport = ClipboardStagingBridge

