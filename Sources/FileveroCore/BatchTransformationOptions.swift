import Foundation

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, center, bottomLeft, bottom, bottomRight, tiled
    
    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        case .tiled: return "Tiled"
        }
    }
}

public struct WatermarkOptions: Codable, Sendable, Equatable {
    public var text = "© Filevero"
    /// When set, the image is drawn instead of the text.
    public var logo: URL? = nil
    public var position: WatermarkPosition = .bottomRight
    public var opacity = 0.5
    /// Watermark width as a fraction of the page or image width.
    public var scale = 0.25
    public var color = "#FFFFFF"
    
    public init() {}
}

public enum UniformSizeMode: String, Codable, CaseIterable, Sendable {
    /// Keeps the whole image and fills the rest with the background color.
    case fit
    /// Fills the canvas and crops what does not fit, keeping the center.
    case fill
}

public struct UniformSizeOptions: Codable, Sendable, Equatable {
    public var width = 1080
    public var height = 1080
    public var mode: UniformSizeMode = .fit
    public var background = "#FFFFFF"
    
    public init() {}
}

public struct AnimationOptions: Codable, Sendable, Equatable {
    /// "gif" or "mp4".
    public var format = "gif"
    public var secondsPerImage = 1.0
    /// Longest edge of the frames in pixels.
    public var maxDimension = 1080
    public var background = "#000000"
    
    public init() {}
}

public enum PageNumberPosition: String, Codable, CaseIterable, Sendable {
    case bottomCenter, bottomRight, bottomLeft, topRight
    
    public var title: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        }
    }
}

public struct PageNumberOptions: Codable, Sendable, Equatable {
    public var position: PageNumberPosition = .bottomCenter
    public var startNumber = 1
    /// Adds the page count, for example "3 / 12".
    public var showTotal = false
    public var fontSize = 11.0
    
    public init() {}
    
    public func label(page: Int, count: Int) -> String {
        let number = startNumber + page
        return showTotal ? "\(number) / \(startNumber + count - 1)" : "\(number)"
    }
}

