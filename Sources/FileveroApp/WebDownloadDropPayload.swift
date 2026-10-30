import AppKit
import FileveroCore

/// Decodes drag-and-drop representations of URLs, browser bookmarks, and embedded media.
public enum WebDownloadDropPayload {
    private static let htmlTypes = [
        NSPasteboard.PasteboardType.html,
        .init("org.chromium.image-html"),
        .init("text/html"),
    ]
    private static let urlTypes = [
        NSPasteboard.PasteboardType.URL,
        .string,
        .init("text/uri-list"),
    ]
    private static let listTypes = [
        NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
        .init("dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k"),
    ]
    private static let baseTypes = [
        NSPasteboard.PasteboardType("org.chromium.source-url"),
        .init("org.chromium.chromium-renderer-initiated-drag"),
    ]

    public static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + urlTypes + htmlTypes + listTypes
    }

    private static var providerFormats: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .html, .init("org.chromium.image-html")]
            + listTypes.filter { $0.rawValue.hasPrefix("dyn.") } + baseTypes
    }

    public static var providerTypes: [String] {
        providerFormats.map(\.rawValue)
    }

    public static func urls(from board: NSPasteboard) -> [URL] {
        if board.types?.contains(.fileURL) == true,
           let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            return files
        }

        let collector = RepresentationCollector()
        for type in urlTypes + htmlTypes + listTypes + baseTypes {
            if let value = board.data(forType: type) {
                collector.add(value, type: type.rawValue)
            }
        }

        for item in (board.pasteboardItems ?? []).prefix(16) {
            for type in urlTypes + htmlTypes + listTypes + baseTypes {
                if let value = item.data(forType: type) {
                    collector.add(value, type: type.rawValue)
                }
            }
        }

        return collector.resolved()
    }

    public static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let collector = RepresentationCollector()

        for (index, provider) in providers.enumerated() {
            for type in providerFormats where provider.hasItemConformingToTypeIdentifier(type.rawValue) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: type.rawValue) { data, _ in
                    if let data {
                        collector.add(data, type: type.rawValue, index: index)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(collector.resolved())
        }
    }

    public static func clipboardLink() -> URL? {
        urls(from: .general).first(where: { !$0.isFileURL })
    }

    private final class RepresentationCollector: @unchecked Sendable {
        private let stateLock = NSLock()
        private var entries: [(Int, String, Data)] = []

        func add(_ data: Data, type: String, index: Int = 0) {
            guard data.count <= 131_072 else { return }
            stateLock.lock()
            defer { stateLock.unlock() }
            entries.append((index, type, data))
        }

        func resolved() -> [URL] {
            stateLock.lock()
            let snapshot = entries.sorted { $0.0 < $1.0 }
            stateLock.unlock()

            var files: [URL] = []
            var links: [String] = []
            var htmlChunks: [String] = []
            var basePrefixes: [String] = []

            for (_, type, data) in snapshot {
                if listTypes.contains(where: { $0.rawValue == type }),
                   let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String]],
                   let firstLinks = plist.first {
                    links += firstLinks
                    continue
                }

                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                    continue
                }

                if type == NSPasteboard.PasteboardType.fileURL.rawValue {
                    if let url = URL(string: text), url.isFileURL { files.append(url) }
                    continue
                }

                if htmlTypes.contains(where: { $0.rawValue == type }) {
                    htmlChunks.append(text)
                } else if baseTypes.contains(where: { $0.rawValue == type }) {
                    basePrefixes.append(text)
                } else if type == "text/uri-list" {
                    links += text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                } else {
                    links.append(text)
                }
            }

            if !files.isEmpty { return files }
            return WebMediaDragPayload.parse(urls: links, html: htmlChunks, baseURLs: basePrefixes)?.urls ?? []
        }
    }
}

// Backward-compatibility alias
public typealias WebLinkPayload = WebDownloadDropPayload

