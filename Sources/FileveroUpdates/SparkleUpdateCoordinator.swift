import AppKit
import Combine
import Sparkle

/// Coordinates Sparkle updates from the public release feed and holds an install's relaunch while a task runs.
@MainActor
public final class SparkleUpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var configurationError: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var sessionInProgress = false
    @Published public private(set) var waitingForCurrentTask = false
    @Published public private(set) var isBusy = false

    private var updaterController: SPUStandardUpdaterController?
    private var releaseConfig: UpdateReleaseConfiguration?
    private var keyObservers: [NSKeyValueObservation] = []
    private var deferredInstallClosure: (() -> Void)?
    private let applicationBundleInfo: [String: Any]

    // Builds up to 1.0.5 could check a GitHub repository chosen in the app. While connected they switched Sparkle's
    // own checks off and kept the user's choice here, so it goes back to Sparkle when the connection is dropped.
    nonisolated static let legacyConnectionKeys = [
        "FileveroUpdateGitHubRepository", "FileveroUpdateGitHubRequiresToken", "FileveroUpdateGitHubSavedToken",
        "FileveroUpdateGitHubAutomaticChecks", "FileveroUpdatePreviousAutomaticChecks", "FileveroPublicChannelMigration",
    ]

    public var isConfigured: Bool {
        updaterController != nil && configurationError == nil
    }

    public override convenience init() {
        self.init(defaults: .standard)
    }

    public init(defaults: UserDefaults, info: [String: Any]? = nil) {
        self.applicationBundleInfo = info ?? Bundle.main.infoDictionary ?? [:]
        super.init()
        Self.removeLegacyConnection(from: defaults)
    }

    nonisolated static func removeLegacyConnection(from defaults: UserDefaults) {
        if defaults.object(forKey: "FileveroUpdateGitHubRepository") != nil {
            let automatic = defaults.object(forKey: "FileveroUpdateGitHubAutomaticChecks") as? Bool ?? true
            defaults.set(automatic, forKey: "SUEnableAutomaticChecks")
        }
        for key in legacyConnectionKeys {
            defaults.removeObject(forKey: key)
        }
    }

    public func start() {
        guard updaterController == nil else { return }
        do {
            releaseConfig = try UpdateReleaseConfiguration(info: applicationBundleInfo)
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            try controller.updater.start()
            self.updaterController = controller
            self.configurationError = nil

            let updater = controller.updater
            keyObservers = [
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] observed, change in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed else { return }
                        self.canCheckForUpdates = change.newValue ?? false
                    }
                },
                updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] observed, change in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed else { return }
                        self.automaticallyChecksForUpdates = change.newValue ?? false
                    }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] observed, _ in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed else { return }
                        self.lastCheckedAt = observed.lastUpdateCheckDate
                    }
                },
                updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] observed, change in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed else { return }
                        self.sessionInProgress = change.newValue ?? false
                    }
                },
            ]
        } catch {
            configurationError = error.localizedDescription
        }
    }

    public func checkForUpdates() {
        guard let controller = updaterController, controller.updater.canCheckForUpdates, !isBusy else { return }
        lastError = nil
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        releaseConfig?.feedURL.absoluteString
    }

    public func setBusy(_ busy: Bool) {
        isBusy = busy
        if !busy, let installHandler = deferredInstallClosure {
            deferredInstallClosure = nil
            waitingForCurrentTask = false
            installHandler()
        }
    }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    public func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        deferredInstallClosure = nil
        waitingForCurrentTask = false
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        lastError = nil
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        lastError = nil
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != SUSparkleErrorDomain || nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        deferredInstallClosure = nil
        waitingForCurrentTask = false
        lastError = nsError.localizedDescription
    }

    public func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeRelaunchIfBusy(installHandler)
    }

    public func postponeRelaunchIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        deferredInstallClosure = installHandler
        waitingForCurrentTask = true
        return true
    }
}

// Backward-compatibility alias
public typealias AppUpdater = SparkleUpdateCoordinator
