import AppKit
import Combine
import FileveroCore
import Foundation
import os

public enum OutputQuality: String, Codable, CaseIterable, Identifiable {
    case smaller
    case balanced
    case higher

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smaller: return "Smaller File"
        case .balanced: return "Balanced"
        case .higher: return "Higher Quality"
        }
    }

    public var value: Double {
        switch self {
        case .smaller: return 0.45
        case .balanced: return 0.8
        case .higher: return 0.95
        }
    }
}

public struct OutputFormatProfile: Codable, Equatable {
    public var quality: OutputQuality = .balanced
    public var preserveMetadata = true
    public var audioBitrate = 256
    public var audioSampleDepth = "matchSource"
    public var videoMaxHeight = 0
    public var videoEncoder = "software"
    public var videoBitrateKbps = 6000
    public var gifFrameRate = 15
    public var gifMaxWidth = 960
    public var compressionPreset = "balanced"
    public var epubLayout = "reflowable"
    public var pdfOfficeLayout = "editable"

    public init(format: String = "") {
        if format.lowercased() == "mov" { quality = .higher }
    }

    private enum CodingKeys: String, CodingKey {
        case quality, preserveMetadata, audioBitrate, audioSampleDepth, videoMaxHeight, videoEncoder, videoBitrateKbps,
             gifFrameRate, gifMaxWidth, compressionPreset, epubLayout, pdfOfficeLayout
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(OutputQuality.self, forKey: .quality) ?? .balanced
        preserveMetadata = try container.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? true
        audioBitrate = try container.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? 256
        audioSampleDepth = try container.decodeIfPresent(String.self, forKey: .audioSampleDepth) ?? "matchSource"
        videoMaxHeight = try container.decodeIfPresent(Int.self, forKey: .videoMaxHeight) ?? 0
        videoEncoder = try container.decodeIfPresent(String.self, forKey: .videoEncoder) ?? "software"
        videoBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? 6000
        gifFrameRate = try container.decodeIfPresent(Int.self, forKey: .gifFrameRate) ?? 15
        gifMaxWidth = try container.decodeIfPresent(Int.self, forKey: .gifMaxWidth) ?? 960
        compressionPreset = try container.decodeIfPresent(String.self, forKey: .compressionPreset) ?? "balanced"
        epubLayout = try container.decodeIfPresent(String.self, forKey: .epubLayout) ?? "reflowable"
        pdfOfficeLayout = try container.decodeIfPresent(String.self, forKey: .pdfOfficeLayout) ?? "editable"
    }
}

@MainActor
public final class FormatPreferencesController: ObservableObject {
    public static let shared = FormatPreferencesController()
    private let storage: UserDefaults
    @Published public private(set) var revision = 0

    public init(defaults: UserDefaults = .standard) {
        self.storage = defaults
    }

    public static func normalize(_ format: String) -> String {
        let normalized = format.lowercased()
        return [
            "jpeg": "jpg",
            "tif": "tiff",
            "heif": "heic",
            "aif": "aiff",
            "gzip": "gz",
            "tgz": "gz",
            "tbz2": "bz2",
            "tbz": "bz2",
            "txz": "xz",
            "markdown": "md"
        ][normalized] ?? normalized
    }

    private func key(for format: String) -> String {
        "conversionProfile." + Self.normalize(format)
    }

    public func profile(for format: String) -> OutputFormatProfile {
        guard let data = storage.data(forKey: key(for: format)),
              let value = try? JSONDecoder().decode(OutputFormatProfile.self, from: data)
        else {
            return .init(format: Self.normalize(format))
        }
        return value
    }

    public func save(_ profile: OutputFormatProfile, for format: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        storage.set(data, forKey: key(for: format))
        revision += 1
    }

    public func restoreDefaults(for format: String) {
        storage.removeObject(forKey: key(for: format))
        revision += 1
    }

    public func options(for format: String) -> OperationOptions {
        let prof = profile(for: format)
        var options = OperationOptions()
        options.quality = prof.quality.value
        options.preserveMetadata = prof.preserveMetadata
        options.audioBitrate = prof.audioBitrate
        options.audioSampleDepth = prof.audioSampleDepth
        options.videoMaxHeight = prof.videoMaxHeight
        options.videoEncoder = prof.videoEncoder
        options.videoBitrateKbps = prof.videoBitrateKbps
        options.gifFrameRate = prof.gifFrameRate
        options.gifMaxWidth = prof.gifMaxWidth
        options.compressionPreset = prof.compressionPreset
        options.epubLayout = prof.epubLayout
        options.pdfOfficeLayout = prof.pdfOfficeLayout
        return options
    }

    public var imageCompressionStrength: String {
        storage.string(forKey: "defaultImageCompressionStrength") ?? "balanced"
    }

    public var imageCompressionSize: String {
        storage.string(forKey: "defaultImageCompressionSize") ?? "original"
    }

    public var videoCompressionStrength: String {
        storage.string(forKey: "defaultVideoCompressionStrength") ?? "balanced"
    }

    public func setCompression(_ value: String, key: String) {
        storage.set(value, forKey: key)
        revision += 1
    }

    public func restoreCompressionDefaults(video: Bool) {
        let keys = video
            ? ["defaultVideoCompressionStrength"]
            : ["defaultImageCompressionStrength", "defaultImageCompressionSize"]
        for k in keys {
            storage.removeObject(forKey: k)
        }
        revision += 1
    }
}

// Backward-compatibility alias
public typealias FormatPreferences = FormatPreferencesController

public struct FormatPreferenceItem: Identifiable, Hashable {
    public let id: String
    public let group: String

    public init(id: String, group: String) {
        self.id = id
        self.group = group
    }

    public var title: String {
        switch id {
        case "md": return "Markdown"
        case "textclipping": return "Text Clipping"
        default: return Self.label(for: id)
        }
    }

    /// Short button label; compressed TAR formats are named after their compressor.
    public static func label(for format: String) -> String {
        ["gz": "GZIP", "bz2": "BZIP2"][format] ?? format.uppercased()
    }

    public var isInputOnly: Bool {
        ["svg", "ppt", "xls", "rtf", "rtfd", "textclipping", "rar", "doc", "odt", "aac", "m4v"].contains(id)
    }

    public var compatibilityLabel: String {
        isInputOnly ? "Input-only format." : "Input and output format."
    }

    public var symbol: String {
        switch group {
        case "Images": return "photo"
        case "Audio": return "waveform"
        case "Video": return "film"
        case "Archives": return "archivebox"
        case "Spreadsheets": return "tablecells"
        case "Subtitles": return "captions.bubble"
        default: return "doc.text"
        }
    }

    public static let groups: [(String, [String])] = [
        ("Images", ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]),
        (
            "Documents",
            [
                "pdf", "docx", "doc", "odt", "pages", "ppt", "pptx", "txt", "md", "rtf", "rtfd", "textclipping", "html",
                "epub",
            ]
        ),
        ("Spreadsheets", ["xlsx", "xls", "ods", "csv", "tsv"]),
        ("Audio", ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "wma"]),
        ("Video", ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "gif"]),
        ("Archives", ["zip", "7z", "tar", "gz", "bz2", "xz", "rar"]),
        ("Subtitles", ["srt", "vtt"]),
    ]

    public static let all: [FormatPreferenceItem] = groups.flatMap { group, formats in
        formats.map { .init(id: $0, group: group) }
    }
}

public struct AllowedFolder: Codable, Identifiable {
    public let path: String
    public let bookmark: Data
    public var id: String { path }

    public init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

public enum OutputNamePreference {
    public static let key = "outputNameTemplate"

    public static func template(defaults: UserDefaults = .standard) -> String? {
        template(from: defaults.string(forKey: key) ?? "")
    }

    public static func template(from value: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}

public enum FolderAccessPreferences {
    private static let key = "folderAccessBookmarks"
    // Jobs ask for access once per input URL; resolving a bookmark each time is a needless round trip.
    private static let resolvedBookmarks = OSAllocatedUnfairLock(initialState: [Data: URL]())
    private static let grantsWriteLock = NSLock()

    public static func grants(defaults: UserDefaults = .standard) -> [AllowedFolder] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AllowedFolder].self, from: data)) ?? []
    }

    public static func resolved(_ grant: AllowedFolder, defaults: UserDefaults = .standard) -> URL? {
        if let cached = resolvedBookmarks.withLock({ $0[grant.bookmark] }) { return cached }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: grant.bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        else { return nil }
        resolvedBookmarks.withLock { $0[grant.bookmark] = url }
        if stale { refreshBookmark(of: grant, at: url, defaults: defaults) }
        return url
    }

    /// A stale bookmark still resolves now but may stop resolving later (for example after the
    /// folder moves), so it is re-created while it can still grant access.
    private static func refreshBookmark(of grant: AllowedFolder, at url: URL, defaults: UserDefaults) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard
            let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        else { return }
        resolvedBookmarks.withLock { $0[data] = url }
        grantsWriteLock.withLock {
            let updated = grants(defaults: defaults).map {
                $0.id == grant.id && $0.bookmark == grant.bookmark ? AllowedFolder(path: $0.path, bookmark: data) : $0
            }
            if let encoded = try? JSONEncoder().encode(updated) {
                defaults.set(encoded, forKey: key)
            }
        }
    }

    public static func add(_ urls: [URL], defaults: UserDefaults = .standard) throws {
        try grantsWriteLock.withLock {
            var current = grants(defaults: defaults)
            for url in urls {
                let canonical = url.standardizedFileURL
                guard !current.contains(where: { $0.path == canonical.path }) else { continue }
                let data = try canonical.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                current.append(.init(path: canonical.path, bookmark: data))
            }
            defaults.set(try JSONEncoder().encode(current), forKey: key)
        }
    }

    public static func remove(_ grant: AllowedFolder, defaults: UserDefaults = .standard) {
        grantsWriteLock.withLock {
            let remaining = grants(defaults: defaults).filter { $0.id != grant.id }
            if let data = try? JSONEncoder().encode(remaining) {
                defaults.set(data, forKey: key)
            }
        }
    }

    public static func withAccess<T>(to output: URL, defaults: UserDefaults = .standard, _ action: () throws -> T) rethrows -> T {
        let path = output.standardizedFileURL.path
        let folders = grants(defaults: defaults).compactMap { resolved($0, defaults: defaults) }.filter { url in
            let parent = url.standardizedFileURL.path
            return path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/")
        }
        let active = folders.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in active {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try action()
    }
}

