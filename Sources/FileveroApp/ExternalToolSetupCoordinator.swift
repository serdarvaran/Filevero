import Combine
import FileveroCore
import Foundation

// MARK: - ExternalToolSetupCoordinator: Asynchronous Dependency Installation Manager

@MainActor public final class ExternalToolSetupCoordinator: ObservableObject {
    public typealias Install = (ToolGroup, CancellationToken, @escaping @Sendable (Double?, String) -> Void) async throws -> Void

    @Published public private(set) var status: ToolSetupStatus
    @Published public private(set) var working = false
    @Published public private(set) var fraction: Double?
    @Published public private(set) var message: String

    private let probe: () -> ToolSetupStatus
    private let installer: Install
    private var task: Task<Void, Never>?
    private var token = CancellationToken()
    public var onWorkingChange: (Bool) -> Void = { _ in }

    public init(
        probe: @escaping () -> ToolSetupStatus = { ExternalToolSetup.status },
        install: @escaping Install = { group, token, report in
            if group == .media {
                try await ExternalToolSetup.installMedia(token: token, progress: report)
            } else {
                try await ExternalToolSetup.installOffice(token: token, progress: report)
            }
        }
    ) {
        self.probe = probe
        self.installer = install
        let initial = probe()
        status = initial
        message =
            initial.ready
            ? "Ready. You can go back to your files."
            : "Download the missing tools to enable all conversions, previews and web downloads. Tools already found on your computer are kept."
    }

    public func refresh() {
        guard !working else { return }
        let previouslyReady = status.ready
        status = probe()
        if status.ready {
            message = "Ready. You can go back to your files."
        } else if previouslyReady {
            message =
                "Download the missing tools to enable all conversions, previews and web downloads. Tools already found on your computer are kept."
        }
    }

    public func install(_ group: ToolGroup? = nil) {
        guard !working else { return }
        refresh()
        let groups = status.missing.filter { group == nil || $0 == group }
        guard !groups.isEmpty else { return }
        working = true
        fraction = nil
        token = CancellationToken()
        onWorkingChange(true)
        let currentToken = token
        task = Task {
            defer {
                status = probe()
                working = false
                onWorkingChange(false)
                task = nil
                NotificationCenter.default.post(name: .toolSetupChanged, object: nil)
            }
            do {
                for (index, item) in groups.enumerated() {
                    try currentToken.check()
                    try Task.checkCancellation()
                    let report: @Sendable (Double?, String) -> Void = { [weak self] value, label in
                        Task { @MainActor in
                            guard let self, self.working, !currentToken.isCancelled else { return }
                            self.fraction = value.map { (Double(index) + $0) / Double(groups.count) }
                            self.message = label
                        }
                    }
                    try await installer(item, currentToken, report)
                    status = probe()
                }
                guard probe().missing.allSatisfy({ !groups.contains($0) }) else {
                    throw FileveroError.failed("The downloaded tools are incomplete. Please try setup again.")
                }
                message =
                    probe().ready
                    ? "Ready. You can go back to your files."
                    : "One tool group is ready. Download the remaining tools to finish setup."
                fraction = 1
            } catch {
                message =
                    currentToken.isCancelled || error is CancellationError
                    ? "Setup cancelled. Existing tools were kept." : error.localizedDescription
            }
        }
    }

    public func cancel() {
        token.cancel()
        task?.cancel()
    }
}

// MARK: - Compatibility Bridge
public typealias ToolSetupModel = ExternalToolSetupCoordinator

