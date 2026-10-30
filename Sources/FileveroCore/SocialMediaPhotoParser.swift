import Foundation

public struct WebPhoto: Identifiable, Sendable {
    public let id: Int
    public let url: URL
    public let width: Int?
    public let height: Int?
    
    public init(id: Int, url: URL, width: Int?, height: Int?) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
    }
}

/// Parses multi-image social carousel payloads and resolves highest-resolution original image CDN links.
enum SocialMediaPhotoParser {
    
    static func parse(_ data: Data, url: URL) throws -> WebMediaInfo {
        guard WebMediaDragPayload.isInstagramPhotoPost(url),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FileveroError.failed("The post did not return readable photo details.")
        }
        
        let entries = (root["entries"] as? [[String: Any]]) ?? [root]
        guard !entries.isEmpty, entries.count <= 50 else {
            throw FileveroError.unsupported("Use one Instagram photo post with up to 50 items.")
        }
        
        var photos: [WebPhoto] = []
        var videoCount = 0
        
        for (index, entry) in entries.enumerated() {
            let formats = entry["formats"] as? [[String: Any]] ?? []
            let hasVideo = formats.contains { ($0["url"] as? String) != nil } || (entry["duration"] as? Double ?? 0) > 0
            if hasVideo {
                videoCount += 1
                continue
            }
            
            let variants = (entry["thumbnails"] as? [[String: Any]] ?? []).compactMap { item -> (URL, Int?, Int?)? in
                guard let text = item["url"] as? String,
                      let imageURL = try? WebDownloadEngine.link(text),
                      imageURL.scheme == "https",
                      let host = imageURL.host?.lowercased(),
                      ["instagram.com", "cdninstagram.com", "fbcdn.net"].contains(where: {
                          host == $0 || host.hasSuffix("." + $0)
                      })
                else { return nil }
                
                func dimension(_ key: String) -> Int? {
                    (item[key] as? Int).flatMap { (1...16_384).contains($0) ? $0 : nil }
                }
                return (imageURL, dimension("width"), dimension("height"))
            }
            
            func qualityScore(_ item: (URL, Int?, Int?), index: Int) -> (Int, Int, Int, Int) {
                let transform = URLComponents(url: item.0, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first { $0.name == "stp" }?.value ?? item.0.path
                let isCrop = transform.range(of: "(?:^|[_/])c[0-9]+[.]", options: .regularExpression) != nil
                let isScaled = transform.range(of: "(?:^|[_/])[sp][0-9]+x[0-9]+", options: .regularExpression) != nil
                return (isCrop ? 0 : 1, isScaled ? 0 : 1, (item.1 ?? 0) * (item.2 ?? 0), index)
            }
            
            guard let bestCandidate = variants.enumerated().max(by: {
                qualityScore($0.element, index: $0.offset) < qualityScore($1.element, index: $1.offset)
            })?.element else {
                throw FileveroError.failed("A photo in this post is unavailable. Try a fresh public post link.")
            }
            
            photos.append(WebPhoto(id: index + 1, url: bestCandidate.0, width: bestCandidate.1, height: bestCandidate.2))
        }
        
        guard !photos.isEmpty else {
            throw FileveroError.unsupported("This post contains videos, not photos. Use its Reel link to download video.")
        }
        
        return WebMediaInfo(
            url: url,
            title: photos.count == 1 ? "Instagram photo" : "Instagram photos",
            kind: .image,
            site: "Instagram",
            duration: nil,
            heights: [],
            direct: false,
            filename: nil,
            byteCount: nil,
            photos: photos,
            skippedVideoCount: videoCount
        )
    }

    static func download(
        _ info: WebMediaInfo,
        selected: Set<Int>?,
        directory: URL,
        token: CancellationToken,
        progress: @escaping ProgressHandler
    ) async throws -> [URL] {
        let allIds = Set(info.photos.map(\.id))
        let targetIds = selected ?? allIds
        guard !targetIds.isEmpty, targetIds.isSubset(of: allIds) else {
            throw FileveroError.invalidInput("Select at least one photo from this post.")
        }
        
        let targetPhotos = info.photos.filter { targetIds.contains($0.id) }
        let shortcode = info.url.path.split(separator: "/").last.map(String.init) ?? "photos"
        let albumDirectory = directory.appendingPathComponent("Instagram \(shortcode)", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDirectory, withIntermediateDirectories: false)
        
        var generatedOutputs: [URL] = []
        for (index, photo) in targetPhotos.enumerated() {
            try token.check()
            try Task.checkCancellation()
            
            let itemStaging = directory.appendingPathComponent("item-\(photo.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: itemStaging, withIntermediateDirectories: false)
            
            let mediaUnit = WebMediaInfo(
                url: photo.url,
                title: "Photo \(photo.id)",
                kind: .image,
                site: "Instagram",
                duration: nil,
                heights: [],
                direct: true,
                filename: nil,
                byteCount: nil
            )
            
            let downloaded = try await WebDownloadEngine.downloadDirect(
                mediaUnit,
                mode: .original,
                directory: itemStaging,
                token: token
            ) { fraction, _ in
                let currentFraction = fraction.isFinite && fraction >= 0
                    ? (Double(index) + min(1.0, fraction)) / Double(targetPhotos.count)
                    : ProgressTracker.indeterminate
                progress(currentFraction, "Photo \(index + 1) of \(targetPhotos.count)…")
            }
            
            guard downloaded.count == 1, let downloadedFile = downloaded.first else {
                throw FileveroError.failed("A photo could not be downloaded.")
            }
            
            let committedDestination = albumDirectory
                .appendingPathComponent(String(format: "%02d", photo.id))
                .appendingPathExtension(downloadedFile.pathExtension)
                
            try FileManager.default.moveItem(at: downloadedFile, to: committedDestination)
            generatedOutputs.append(committedDestination)
        }
        return generatedOutputs
    }
}

typealias InstagramPhotos = SocialMediaPhotoParser

