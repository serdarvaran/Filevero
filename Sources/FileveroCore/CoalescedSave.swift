import Foundation

/// Coalesces bursts of save requests into at most one write per `interval`.
/// The first request schedules the write; later requests before it runs are absorbed.
/// Call `flush()` before the process exits so the latest state is never left unsaved.
@MainActor
public final class CoalescedSave {
    private let interval: Duration
    private let save: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    public init(interval: Duration, save: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.save = save
    }

    public var hasPendingSave: Bool { pending != nil }

    public func schedule() {
        guard pending == nil else { return }
        let interval = interval
        pending = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    public func flush() {
        guard let task = pending else { return }
        pending = nil
        task.cancel()
        save()
    }
}
