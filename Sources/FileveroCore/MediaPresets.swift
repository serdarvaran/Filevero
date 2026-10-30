import Foundation
import CoreGraphics

/// Defines standardized crop geometries and target resolutions for social media platforms and modern web assets.
public struct SocialMediaPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let platform: String
    public let title: String
    public let width: Int
    public let height: Int
    public let ratioText: String

    public var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(height)
    }

    public var label: String {
        "\(platform) · \(title) (\(ratioText))"
    }

    public init(id: String, platform: String, title: String, width: Int, height: Int, ratioText: String) {
        self.id = id
        self.platform = platform
        self.title = title
        self.width = width
        self.height = height
        self.ratioText = ratioText
    }

    /// Computes a centered crop rectangle for a given image size fitting this preset's aspect ratio.
    public func fit(in size: CGSize) -> EditRect {
        guard size.width > 0, size.height > 0 else {
            return EditRect(x: 0, y: 0, width: Double(width), height: Double(height))
        }
        let targetRatio = aspectRatio
        var cropW = size.width
        var cropH = cropW / targetRatio

        if cropH > size.height {
            cropH = size.height
            cropW = cropH * targetRatio
        }

        let originX = (size.width - cropW) / 2.0
        let originY = (size.height - cropH) / 2.0
        return EditRect(x: originX, y: originY, width: cropW, height: cropH)
    }

    public static let standardPresets: [SocialMediaPreset] = [
        SocialMediaPreset(id: "ig-square", platform: "Instagram", title: "Square Post", width: 1080, height: 1080, ratioText: "1:1"),
        SocialMediaPreset(id: "ig-story", platform: "Instagram", title: "Story / Reel", width: 1080, height: 1920, ratioText: "9:16"),
        SocialMediaPreset(id: "ig-portrait", platform: "Instagram", title: "Portrait Post", width: 1080, height: 1350, ratioText: "4:5"),
        SocialMediaPreset(id: "yt-thumb", platform: "YouTube", title: "Thumbnail", width: 1280, height: 720, ratioText: "16:9"),
        SocialMediaPreset(id: "x-post", platform: "X (Twitter)", title: "Feed Post", width: 1200, height: 675, ratioText: "16:9"),
        SocialMediaPreset(id: "x-header", platform: "X (Twitter)", title: "Header Banner", width: 1500, height: 500, ratioText: "3:1"),
        SocialMediaPreset(id: "li-post", platform: "LinkedIn", title: "Feed Post", width: 1200, height: 627, ratioText: "1.91:1"),
        SocialMediaPreset(id: "li-banner", platform: "LinkedIn", title: "Profile Banner", width: 1584, height: 396, ratioText: "4:1"),
        SocialMediaPreset(id: "fb-post", platform: "Facebook", title: "Feed Image", width: 1200, height: 630, ratioText: "1.91:1"),
        SocialMediaPreset(id: "web-hero", platform: "Web", title: "Hero Banner", width: 1920, height: 1080, ratioText: "16:9"),
        SocialMediaPreset(id: "web-standard", platform: "Web", title: "Standard Landscape", width: 1200, height: 800, ratioText: "3:2"),
        SocialMediaPreset(id: "avatar", platform: "Profile", title: "Avatar", width: 500, height: 500, ratioText: "1:1"),
    ]
}

