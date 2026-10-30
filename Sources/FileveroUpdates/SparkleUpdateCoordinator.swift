import AppKit
import Combine
import Sparkle

/// Coordinates Sparkle framework updates, private release loopback bridges, and safe background checks.
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
    @Published public private(set) var repository: GitHubRepository?
    @Published public private(set) var requiresToken = true
    @Published public private(set) var hasSavedToken = false
    @Published public private(set) var isConnecting = false
    @Published public private(set) var isPreparingCheck = false

    private var updaterController: SPUStandardUpdaterController?
    private var releaseConfig: UpdateReleaseConfiguration?
    private var keyObservers: [NSKeyValueObservation] = []
    private var deferredInstallClosure: (() -> Void)?
    private let credentialStore: UpdateCredentialStore
    private let userDefaults: UserDefaults
    private let applicationBundleInfo: [String: Any]

    public var officialRepository: GitHubRepository? {
        UpdateChannelDescriptor(info: applicationBundleInfo)?.repository
    }

    private let accessValidator: (GitHubRepository, String?) async throws -> Void
    private var loopbackBridge: GitHubReleaseBridge?
    private var backgroundCheckTask: Task<Void, Never>?
    private var sparkleAllowsCheck = false
    private var sparkleIsActiveSession = false

    private enum SettingsKey {
        static let repoSlug = "FileveroUpdateGitHubRepository"
        static let needsToken = "FileveroUpdateGitHubRequiresToken"
        static let tokenPersisted = "FileveroUpdateGitHubSavedToken"
        static let autoCheck = "FileveroUpdateGitHubAutomaticChecks"
        static let priorAutoCheck = "FileveroUpdatePreviousAutomaticChecks"
    }

    public var isConfigured: Bool {
        updaterController != nil && configurationError == nil
    }

    public var canChangeConnection: Bool {
        !sessionInProgress && updaterController?.updater.sessionInProgress != true && !isConnecting && !isBusy && !waitingForCurrentTask
    }

    public override convenience init() {
        self.init(credentials: BrokerCredentialStore(), defaults: .standard)
    }

    public init(credentials: UpdateCredentialStore, defaults: UserDefaults, info: [String: Any]? = nil) {
        self.credentialStore = credentials
        self.userDefaults = defaults
        self.applicationBundleInfo = info ?? Bundle.main.infoDictionary ?? [:]
        self.accessValidator = { repo, token in
            try await GitHubReleaseTransport(repository: repo, token: token).validateAccess()
        }
        super.init()
        loadPersistedState()
    }

    public init(
        credentials: UpdateCredentialStore,
        defaults: UserDefaults,
        validateAccess: @escaping (GitHubRepository, String?) async throws -> Void,
        info: [String: Any]? = nil
    ) {
        self.credentialStore = credentials
        self.userDefaults = defaults
        self.applicationBundleInfo = info ?? Bundle.main.infoDictionary ?? [:]
        self.accessValidator = validateAccess
        super.init()
        loadPersistedState()
    }

    private func loadPersistedState() {
        UpdateChannelDescriptor(info: applicationBundleInfo)?.migrate(userDefaults)
        if let savedSlug = userDefaults.string(forKey: SettingsKey.repoSlug) {
            if let repo = try? GitHubRepository(savedSlug) {
                repository = repo
            }
        }
        requiresToken = userDefaults.object(forKey: SettingsKey.needsToken) as? Bool ?? (officialRepository == nil)
        hasSavedToken = repository != nil && requiresToken && userDefaults.bool(forKey: SettingsKey.tokenPersisted)
    }

    public func start() {
        guard updaterController == nil else { return }
        do {
            releaseConfig = try UpdateReleaseConfiguration(info: applicationBundleInfo, repository: repository)
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            if repository != nil {
                controller.updater.automaticallyChecksForUpdates = false
            }
            try controller.updater.start()
            self.updaterController = controller
            self.configurationError = nil

            let updater = controller.updater
            keyObservers = [
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] observed, change in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed else { return }
                        self.sparkleAllowsCheck = change.newValue ?? false
                        self.syncStateFlags()
                    }
                },
                updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] observed, change in
                    Task { @MainActor in
                        guard let self, self.updaterController?.updater === observed, self.repository == nil else { return }
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
                        self.sparkleIsActiveSession = change.newValue ?? false
                        self.syncStateFlags()
                    }
                },
            ]
            configureCheckScheduler()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    public func checkForUpdates() {
        guard let controller = updaterController,
              canCheckForUpdates,
              controller.updater.canCheckForUpdates,
              !isBusy,
              !isConnecting
        else {
            return
        }

        lastError = nil
        NSApp.activate(ignoringOtherApps: true)
        if repository != nil, !controller.updater.sessionInProgress {
            Task { await runGitHubUpdateCheck(userInitiated: true) }
        } else {
            controller.checkForUpdates(nil)
        }
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        if repository != nil {
            userDefaults.set(enabled, forKey: SettingsKey.autoCheck)
            automaticallyChecksForUpdates = enabled
            schedulePeriodicCheck(after: 3_600)
        } else {
            updaterController?.updater.automaticallyChecksForUpdates = enabled
        }
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        if repository != nil {
            return activeBridgeFeedURL?.absoluteString
        }
        return releaseConfig?.feedURL.absoluteString
    }

    private var activeBridgeFeedURL: URL?

    public func connectGitHub(repository inputSlug: String, token inputToken: String, requiresToken: Bool) async throws {
        guard canChangeConnection else { throw ConnectionError.inProgress }
        isConnecting = true
        syncStateFlags()
        defer {
            isConnecting = false
            syncStateFlags()
        }

        let targetRepo = try GitHubRepository(inputSlug)
        let trimmedToken = inputToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken: String?
        if requiresToken {
            resolvedToken = trimmedToken.isEmpty
                ? try await credentialStore.loadToken(for: targetRepo, authorizingAccess: true)
                : try KeychainCredentialStore.validate(trimmedToken)
        } else {
            resolvedToken = nil
        }

        try await accessValidator(targetRepo, resolvedToken)

        if let token = resolvedToken {
            try await credentialStore.storeToken(token, for: targetRepo)
        } else {
            try await credentialStore.removeToken(for: targetRepo)
        }

        if let prior = repository, prior != targetRepo {
            try await credentialStore.removeToken(for: prior)
        }

        if repository == nil, let controller = updaterController {
            userDefaults.set(controller.updater.automaticallyChecksForUpdates, forKey: SettingsKey.priorAutoCheck)
        }

        teardownBridge()
        userDefaults.set(targetRepo.slug, forKey: SettingsKey.repoSlug)
        userDefaults.set(requiresToken, forKey: SettingsKey.needsToken)
        userDefaults.set(requiresToken, forKey: SettingsKey.tokenPersisted)

        self.repository = targetRepo
        self.requiresToken = requiresToken
        self.hasSavedToken = requiresToken
        self.availableVersion = nil
        self.lastError = nil

        if updaterController == nil {
            start()
        } else {
            configureCheckScheduler()
        }
    }

    public func disconnectGitHub() async throws {
        guard canChangeConnection else { throw ConnectionError.inProgress }
        isConnecting = true
        syncStateFlags()
        defer {
            isConnecting = false
            syncStateFlags()
        }

        if let repo = repository {
            try await credentialStore.removeToken(for: repo)
        }
        backgroundCheckTask?.cancel()
        teardownBridge()

        for key in [SettingsKey.repoSlug, SettingsKey.needsToken, SettingsKey.tokenPersisted] {
            userDefaults.removeObject(forKey: key)
        }

        repository = nil
        hasSavedToken = false
        availableVersion = nil
        lastError = nil

        do {
            releaseConfig = try UpdateReleaseConfiguration(info: applicationBundleInfo)
            if let controller = updaterController {
                controller.updater.automaticallyChecksForUpdates = userDefaults.object(forKey: SettingsKey.priorAutoCheck) as? Bool ?? true
                configureCheckScheduler()
            }
        } catch {
            updaterController?.updater.automaticallyChecksForUpdates = false
            keyObservers.removeAll()
            updaterController = nil
            releaseConfig = nil
            configurationError = error.localizedDescription
            sparkleAllowsCheck = false
            sparkleIsActiveSession = false
            automaticallyChecksForUpdates = false
            syncStateFlags()
        }
    }

    private func syncStateFlags() {
        sessionInProgress = (updaterController?.updater.sessionInProgress ?? sparkleIsActiveSession) || isPreparingCheck
        canCheckForUpdates = (updaterController?.updater.canCheckForUpdates ?? sparkleAllowsCheck) && !isPreparingCheck && !isConnecting
    }

    private func configureCheckScheduler() {
        backgroundCheckTask?.cancel()
        guard let controller = updaterController else { return }

        if repository != nil {
            controller.updater.automaticallyChecksForUpdates = false
            automaticallyChecksForUpdates = userDefaults.object(forKey: SettingsKey.autoCheck) as? Bool ?? true
            schedulePeriodicCheck(after: 4)
        } else {
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        }
    }

    private func schedulePeriodicCheck(after delay: TimeInterval) {
        backgroundCheckTask?.cancel()
        guard repository != nil, automaticallyChecksForUpdates, isConfigured else { return }

        backgroundCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }

            if self.isBusy || self.sessionInProgress || self.isConnecting || !self.canCheckForUpdates {
                self.schedulePeriodicCheck(after: 60)
            } else {
                await self.runGitHubUpdateCheck(userInitiated: false)
            }
        }
    }

    private func runGitHubUpdateCheck(userInitiated: Bool) async {
        guard let repo = repository,
              let controller = updaterController,
              canCheckForUpdates,
              controller.updater.canCheckForUpdates,
              !isBusy,
              !isConnecting
        else {
            return
        }

        isPreparingCheck = true
        syncStateFlags()
        lastError = nil

        defer {
            isPreparingCheck = false
            syncStateFlags()
            schedulePeriodicCheck(after: 3_600)
        }

        do {
            let token = requiresToken ? try await credentialStore.loadToken(for: repo) : nil
            let transport = GitHubReleaseTransport(repository: repo, token: token)
            let feedData = try await transport.fetchLatestAppcast()
            try Task.checkCancellation()

            let bridge = GitHubReleaseBridge(client: transport, appcast: feedData)
            let loopbackURL = try await bridge.start()
            do {
                try Task.checkCancellation()
            } catch {
                bridge.stop()
                throw error
            }

            teardownBridge()
            self.loopbackBridge = bridge
            self.activeBridgeFeedURL = loopbackURL

            controller.updater.httpHeaders = nil
            if userInitiated {
                controller.checkForUpdates(nil)
            } else {
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
                lastCheckedAt = Date()
            }
        }
    }

    private func teardownBridge() {
        loopbackBridge?.stop()
        loopbackBridge = nil
        activeBridgeFeedURL = nil
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if repository != nil, activeBridgeFeedURL == nil {
            throw ConnectionError.reconnect
        }
    }

    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard repository != nil else { return }
        guard let bridge = loopbackBridge, let fileURL = item.fileURL else {
            throw ConnectionError.reconnect
        }
        _ = try bridge.archiveURL(for: fileURL)
    }

    public func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard repository != nil else { return }
        do {
            guard let bridge = loopbackBridge, let url = request.url else {
                throw ConnectionError.reconnect
            }
            request.url = try bridge.archiveURL(for: url)
            request.allHTTPHeaderFields = ["User-Agent": "Filevero updater"]
        } catch {
            request.url = URL(string: "http://127.0.0.1:1/unavailable")!
            request.allHTTPHeaderFields = [:]
            lastError = error.localizedDescription
        }
    }

    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool {
        repository == nil
    }

    private enum ConnectionError: LocalizedError {
        case inProgress
        case reconnect

        var errorDescription: String? {
            switch self {
            case .inProgress:
                return "Finish the current task or update before changing the update connection."
            case .reconnect:
                return "Check for updates again to reconnect the private download."
            }
        }
    }

    public func setBusy(_ busy: Bool) {
        isBusy = busy
        if !busy, let installHandler = deferredInstallClosure {
            deferredInstallClosure = nil
            waitingForCurrentTask = false
            installHandler()
        }
    }

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    public func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        deferredInstallClosure = nil
        waitingForCurrentTask = false
        teardownBridge()
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

