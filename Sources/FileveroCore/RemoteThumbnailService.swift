import Foundation
import ImageIO

/// Remote video platform thumbnail resolution and image quality maximization service.
public enum RemoteThumbnailService {
    public struct Image: Sendable {
        public let url: URL
        public let width: Int
        public let height: Int
        public let byteCount: Int
        public var area: Int { width * height }

        public init(url: URL, width: Int, height: Int, byteCount: Int) {
            self.url = url
            self.width = width
            self.height = height
            self.byteCount = byteCount
        }
    }

    public static func videoID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/")
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
            url.port == nil || url.port == 443 || url.port == 80,
            host == "img.youtube.com" || host == "ytimg.com" || host.hasSuffix(".ytimg.com"),
            parts.count >= 3, ["vi", "vi_webp", "an_webp"].contains(parts[0])
        else { return nil }
        let id = String(parts[1])
        guard id.utf8.count == 11,
            id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            })
        else { return nil }
        return id
    }

    public static func resolve(
        _ source: URL,
        token: CancellationToken,
        fetch: (URL) async throws -> Data?
    ) async throws -> Image? {
        guard let id = videoID(source) else { return nil }
        let candidates =
            [source]
            + ["maxresdefault", "sddefault", "hqdefault"].compactMap {
                URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg")
            }
        var seen = Set<URL>()
        var best: Image?
        for url in candidates where seen.insert(url).inserted {
            try token.check()
            try Task.checkCancellation()
            do {
                guard let data = try await fetch(url), data.count <= 8 * 1024 * 1024,
                    let image = CGImageSourceCreateWithData(
                        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                    let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                    let width = properties[kCGImagePropertyPixelWidth] as? Int,
                    let height = properties[kCGImagePropertyPixelHeight] as? Int,
                    (1...16_384).contains(width), (1...16_384).contains(height)
                else { continue }
                guard url == source || width > 120 || height > 90 else { continue }
                let found = Image(url: url, width: width, height: height, byteCount: data.count)
                if best == nil || found.area > best!.area { best = found }
            } catch {
                try token.check()
                try Task.checkCancellation()
            }
        }
        try token.check()
        try Task.checkCancellation()
        return best
    }
}

// MARK: - Compatibility Bridge
public typealias YouTubeThumbnail = RemoteThumbnailService

