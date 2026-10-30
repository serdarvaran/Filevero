import Foundation

/// Mathematical and domain utilities for mapping operational progress across nested tasks and pipeline stages.
public enum ProgressTracker {
    public static let indeterminate = -1.0

    /// Normalizes and maps a subtask progress ratio into a bounded parent interval `[start, end]`.
    public static func map(_ value: Double, from start: Double, to end: Double) -> Double {
        guard value.isFinite, value >= 0 else { return indeterminate }
        return start + min(1.0, value) * (end - start)
    }
}

public typealias OperationProgress = ProgressTracker

/// Real-time stream monitor that parses FFmpeg machine-readable microsecond timestamps (`out_time_us=...`)
/// from stdout/stderr drains and converts them into monotonic progress updates.
public final class MediaProgressMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var streamBuffer = Data()
    private var lastEmittedFraction = 0.0
    private let totalDurationSeconds: Double?
    private let onProgress: ProgressHandler

    public init(duration: Double?, progress: @escaping ProgressHandler) {
        self.totalDurationSeconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.onProgress = progress
    }

    public func append(_ incomingData: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        streamBuffer.append(incomingData)
        
        while let newlineIndex = streamBuffer.firstIndex(of: 10) {
            let line = String(decoding: streamBuffer[..<newlineIndex], as: UTF8.self)
            streamBuffer.removeSubrange(...newlineIndex)
            
            guard let totalDuration = totalDurationSeconds,
                  line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)),
                  microseconds.isFinite, microseconds >= 0
            else { continue }
            
            // Cap at 0.995 to reserve completion signal for actual container finalization/muxing.
            let fraction = min(0.995, microseconds / 1_000_000.0 / totalDuration)
            guard fraction > lastEmittedFraction else { continue }
            
            lastEmittedFraction = fraction
            onProgress(fraction, "Processing media…")
        }
        
        // Prevent unbounded memory growth if incoming stream contains no newline delimiters
        if streamBuffer.count > 16_384 {
            streamBuffer.removeAll(keepingCapacity: true)
        }
    }
}

public typealias FFmpegProgressParser = MediaProgressMonitor

