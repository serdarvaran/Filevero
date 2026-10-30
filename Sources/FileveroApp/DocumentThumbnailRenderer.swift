import AppKit
import SwiftUI

/// Timestamp and size snapshot of a file used to invalidate cached thumbnails.
public struct FileArtworkStamp: Equatable, Sendable {
    public let exists: Bool
    public let modified: TimeInterval
    public let size: UInt64
    public let directory: Bool

    public static func read(_ url: URL) -> Self {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .init(exists: false, modified: 0, size: 0, directory: false)
        }
        return .init(
            exists: true,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            directory: attributes[.type] as? FileAttributeType == .typeDirectory
        )
    }
}

/// Thread-safe wrapper holding an immutable NSImage instance.
public final class FileArtworkImage: @unchecked Sendable {
    public let image: NSImage
    public init(_ image: NSImage) {
        self.image = image
    }
}

/// Actor caching Finder thumbnails and custom document icons off the main thread.
public actor FileArtworkCache {
    public static let shared = FileArtworkCache()

    public typealias Loader = @Sendable (URL) -> NSImage?
    public typealias StampReader = @Sendable (URL) -> FileArtworkStamp

    private struct Entry {
        let stamp: FileArtworkStamp
        let image: FileArtworkImage?
        var accessSequence: UInt64
    }

    private let capacity: Int
    private let loader: Loader
    private let stampReader: StampReader
    private var cache: [String: Entry] = [:]
    private var inFlightTasks: [String: Task<FileArtworkImage?, Never>] = [:]
    private var accessCounter: UInt64 = 0

    public init(
        capacity: Int = 128,
        stampReader: @escaping StampReader = { FileArtworkStamp.read($0) },
        loader: @escaping Loader = { NSWorkspace.shared.icon(forFile: $0.path) }
    ) {
        self.capacity = max(1, capacity)
        self.stampReader = stampReader
        self.loader = loader
    }

    public func image(for url: URL) async -> FileArtworkImage? {
        let canonical = url.standardizedFileURL
        let pathKey = canonical.path

        if let existingFlight = inFlightTasks[pathKey] {
            return await existingFlight.value
        }

        let task = Task { await fetchImage(canonical, key: pathKey) }
        inFlightTasks[pathKey] = task
        let result = await task.value
        inFlightTasks[pathKey] = nil
        return result
    }

    private func fetchImage(_ url: URL, key: String) async -> FileArtworkImage? {
        let reader = stampReader
        let currentStamp = await Task.detached(priority: .utility) { reader(url) }.value
        accessCounter &+= 1

        if var hit = cache[key], hit.stamp == currentStamp {
            hit.accessSequence = accessCounter
            cache[key] = hit
            return hit.image
        }

        let workerLoader = loader
        let loaded = await Task.detached(priority: .utility) {
            workerLoader(url).map { FileArtworkImage($0) }
        }.value

        accessCounter &+= 1
        if let loaded {
            cache[key] = Entry(stamp: currentStamp, image: loaded, accessSequence: accessCounter)
        } else {
            cache[key] = nil
        }

        while cache.count > capacity,
              let leastRecent = cache.min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key {
            cache[leastRecent] = nil
        }

        return loaded
    }

    public var cachedCount: Int { cache.count }
    public var pendingCount: Int { inFlightTasks.count }
}

/// SwiftUI view that displays an asynchronous file icon with responsive placeholder states.
public struct AsyncFileArtwork: View {
    public let url: URL
    @State private var iconImage: NSImage?
    @State private var activationPulse: UInt64 = 0

    public init(url: URL) {
        self.url = url
    }

    private var cacheKey: String {
        url.standardizedFileURL.path + "\u{0}" + String(activationPulse)
    }

    public var body: some View {
        Group {
            if let img = iconImage {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .task(id: cacheKey) {
            iconImage = nil
            let artwork = await FileArtworkCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            iconImage = artwork?.image
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activationPulse &+= 1
        }
        .accessibilityHidden(true)
    }
}

// Backward-compatibility aliases
public typealias DocumentThumbnailStamp = FileArtworkStamp
public typealias DocumentThumbnailCache = FileArtworkCache

