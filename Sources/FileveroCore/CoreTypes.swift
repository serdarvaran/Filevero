import Foundation

/// Canonical error representation across Filevero operations and system pipelines.
public enum FileveroError: LocalizedError {
    case invalidInput(String)
    case unsupported(String)
    case failed(String)
    case cancelled
    case missingDependency(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .unsupported(let message), .failed(let message):
            return message
        case .cancelled:
            return "The operation was cancelled."
        case .missingDependency(let component):
            return "Required local component is missing: \(component)"
        }
    }
}

/// Asynchronous progress notification callback passing fractional progress (0.0 ... 1.0 or indeterminate) and status text.
public typealias ProgressHandler = @Sendable (Double, String) -> Void

/// Thread-safe cooperative cancellation token checked by long-running transforms and subprocess runners.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    
    public init() {}
    
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    
    public func check() throws {
        if isCancelled {
            throw FileveroError.cancelled
        }
    }
}

public typealias OperationCancellationToken = CancellationToken

/// Normalized or absolute rectangular coordinate region used for cropping and visual redaction.
public struct EditRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Overlay annotation on an image or document canvas.
public struct Annotation: Codable, Sendable {
    public var rect: EditRect
    public var text: String
    public var color: String
    public var kind: String
    
    public init(rect: EditRect, text: String = "", color: String = "#FF830A", kind: String = "text") {
        self.rect = rect
        self.text = text
        self.color = color
        self.kind = kind
    }
}

/// Temporal interval within a media timeline (audio/video).
public struct TimeRange: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    
    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Spatial and temporal bounds for video redaction intervals.
public struct VideoRedaction: Codable, Sendable {
    public var rect: EditRect
    public var start: Double
    public var end: Double?
    
    public init(rect: EditRect, start: Double = 0, end: Double? = nil) {
        self.rect = rect
        self.start = start
        self.end = end
    }
}

