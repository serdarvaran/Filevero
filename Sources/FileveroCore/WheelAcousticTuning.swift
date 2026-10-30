import Foundation

/// Acoustic parameters for synthetic tactile wheel audio synthesis, matching macOS AppKit and web playground feedback.
public enum WheelAcousticTuning {
    public static let voices = 3
    public static let volume = 0.65
    public static let minimumInterval: TimeInterval = 0.05
}

public typealias WheelFeedbackTuning = WheelAcousticTuning

