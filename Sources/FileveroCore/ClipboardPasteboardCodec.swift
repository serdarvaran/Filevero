import AppKit

/// Converts between a pasteboard and the formats clipboard history keeps.
public enum ClipboardPasteboardCodec {
    private static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let marker = NSPasteboard.PasteboardType(ClipboardHistory.restoreMarker)

    /// Reads content only after the type list shows it may be kept, so concealed passwords and excluded apps'
    /// copies are never read into memory.
    public static func capture(
        _ pasteboard: NSPasteboard, frontmostApp: String?, excludedApps: Set<String> = []
    ) -> ClipboardCapture? {
        let types = pasteboard.types ?? []
        let markers = Set(types.map(\.rawValue))
        let app = pasteboard.string(forType: source).flatMap { $0.isEmpty ? nil : $0 } ?? frontmostApp
        guard markers.isDisjoint(with: ClipboardHistory.ignoredMarkers), !(app.map(excludedApps.contains) ?? false) else {
            return ClipboardCapture(formats: [:], sourceApp: app, markers: markers)
        }
        var formats: [ClipboardFormat: Data] = [:]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
            if !existing.isEmpty { formats[.fileURLs] = Data(existing.joined(separator: "\n").utf8) }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { formats[.plainText] = Data(text.utf8) }
        formats[.rtf] = pasteboard.data(forType: .rtf)
        formats[.html] = pasteboard.data(forType: .html)
        let png = pasteboard.data(forType: .png)
        formats[.png] = png
        let tiff = png == nil ? pasteboard.data(forType: .tiff) : nil
        guard !formats.isEmpty || tiff != nil else { return nil }
        return ClipboardCapture(formats: formats, sourceApp: app, markers: markers, pendingTIFF: tiff)
    }

    /// Encodes a TIFF-only image as PNG. A screenshot takes long enough to encode that this runs off the main thread.
    public static func storable(_ capture: ClipboardCapture) -> ClipboardCapture {
        guard let tiff = capture.pendingTIFF else { return capture }
        var formats = capture.formats
        formats[.png] = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        return ClipboardCapture(formats: formats, sourceApp: capture.sourceApp, markers: capture.markers)
    }

    public static func write(_ formats: [ClipboardFormat: Data], plainTextOnly: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if plainTextOnly, ClipboardHistory.plainText(formats) != nil {
            let item = NSPasteboardItem()
            item.setString(ClipboardHistory.plainText(formats)!, forType: .string)
            item.setData(Data(), forType: marker)
            pasteboard.writeObjects([item])
            return
        }
        let first = NSPasteboardItem()
        let types: [(ClipboardFormat, NSPasteboard.PasteboardType)] = [
            (.plainText, .string), (.rtf, .rtf), (.html, .html), (.png, .png),
        ]
        for (format, type) in types {
            if let data = formats[format] { first.setData(data, forType: type) }
        }
        first.setData(Data(), forType: marker)
        let files = ClipboardHistory.filePaths(formats).map { URL(fileURLWithPath: $0) }
        var items = [first]
        for (index, url) in files.enumerated() {
            let item = index == 0 ? first : NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index > 0 { items.append(item) }
        }
        pasteboard.writeObjects(items)
    }
}
