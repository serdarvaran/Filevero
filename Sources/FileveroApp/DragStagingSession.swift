import Foundation

/// Detects fresh drag sessions by monitoring change count intervals and mouse button states.
public struct DragStagingSession: Sendable {
    private var baselineChangeCount: Int?
    private var previousChangeCount: Int?
    private var lastChangeTimestamp: TimeInterval = -.infinity
    private var buttonWasDown = false

    public init() {}

    public mutating func containsFreshDrag(isDown: Bool, changeCount: Int, now: TimeInterval) -> Bool {
        if baselineChangeCount == nil { baselineChangeCount = changeCount }
        if let prev = previousChangeCount, prev != changeCount { lastChangeTimestamp = now }

        defer {
            previousChangeCount = changeCount
            buttonWasDown = isDown
        }

        if !isDown {
            if buttonWasDown || now - lastChangeTimestamp > 0.2 { baselineChangeCount = changeCount }
            return false
        }
        return changeCount != baselineChangeCount
    }

    /// Records the drag pasteboard as seen when a press begins after an unobserved idle period,
    /// so pasteboard changes made while nobody was polling are not mistaken for a new drag.
    public mutating func observeIdle(changeCount: Int) {
        baselineChangeCount = changeCount
        previousChangeCount = changeCount
        buttonWasDown = false
    }
}

// Backward-compatibility alias
public typealias DragPasteboardSession = DragStagingSession

