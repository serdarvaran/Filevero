import AppKit
import ApplicationServices
import Carbon
import Combine
import FileveroCore
import FileveroUpdates
import ServiceManagement
import SwiftUI

// MARK: - FileveroApplication: Application Entrypoint

@main
public enum FileveroApplication {
    @MainActor
    public static func main() {
        if CommandLine.arguments.count > 1,
           ["convert", "tool", "inspect", "catalog", "dependencies"].contains(CommandLine.arguments[1])
        {
            exit(FileveroCommandLine.run())
        }

        let app = NSApplication.shared

        if CommandLine.arguments.contains("--ui-audit") {
            do {
                let auditOptions = try InterfaceAuditOptions(arguments: CommandLine.arguments)
                let runner = InterfaceAuditCoordinator(options: auditOptions)
                app.delegate = runner
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(runner) { app.run() }
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(64)
            }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--range-accessibility-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = MediaRangeAccessibilitySmokeTest(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--file-artwork-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = FileArtworkSmokeRunner(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--float-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = FloatShelfSmokeTest(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--tool-setup-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = ToolSetupSmokeTest(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--localization-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = LocalizationSmokeTest(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if CommandLine.arguments.contains("--window-management-status") {
            let statusDict: [String: Any] = [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "displayName": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "",
                "accessibilityTrusted": AXIsProcessTrusted()
            ]
            if let data = try? JSONSerialization.data(withJSONObject: statusDict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8)
            {
                print(text)
            }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--window-management-smoke"),
           CommandLine.arguments.count > index + 2,
           let managerPID = Int32(CommandLine.arguments[index + 1])
        {
            let runner = WindowManagementSmokeTestDelegate(
                managerPID: managerPID,
                output: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        if CommandLine.arguments.contains("--window-management-fixture") {
            let fixture = WindowManagementFixtureDelegate()
            app.delegate = fixture
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(fixture) { app.run() }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--desktop-parity-smoke"),
           CommandLine.arguments.count > index + 1
        {
            let runner = DesktopParitySmokeTest(
                output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            )
            app.delegate = runner
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(runner) { app.run() }
            return
        }

        let mainDelegate = FileveroAppDelegate()
        app.delegate = mainDelegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(mainDelegate) { app.run() }
    }
}

// MARK: - Smoke Runners Support

@MainActor
private final class FileArtworkSmokeRunner: NSObject, NSApplicationDelegate {
    let output: URL
    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let report = try await FileArtworkSmokeTest.run(output: output)
                let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try json.write(to: output.appendingPathComponent("file-artwork.json"), options: .atomic)
                print("FILE_ARTWORK PASS \(report["passed"] ?? 0)")
                exit(0)
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
        }
    }
}

@MainActor
private final class WindowManagementFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let testWindow = NSWindow(
            contentRect: NSRect(x: 220, y: 200, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let key = CommandLine.arguments.firstIndex(of: "--minimum-window-width")
        let minimum = key.flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 160
        testWindow.title = "Filevero Window Layout Fixture"
        testWindow.minSize = NSSize(width: min(1200, max(160, minimum)), height: 120)
        testWindow.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "Filevero window arrangement test fixture")
        label.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        label.frame = NSRect(x: 26, y: 300, width: 560, height: 40)
        testWindow.contentView?.addSubview(label)
        testWindow.makeKeyAndOrderFront(nil)
        window = testWindow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - FileveroAppDelegate: Primary Application Lifecycle Coordinator

@MainActor
public final class FileveroAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public let state = AppSessionController()
    public let updater = SparkleUpdateCoordinator()
    private var updateSubscriptions = Set<AnyCancellable>()

    public var statusItem: NSStatusItem!
    public var home: NSWindow?
    private var homeKeyboardEventMonitor: Any?
    public var settings: NSWindow?
    public var updateConnection: NSWindow?
    private let progressToast = ProgressStatusToast()
    public var toolSetupWorking = false
    public var toolSetupWindow: NSWindow?
    private weak var toolSetupModel: ExternalToolSetupCoordinator?
    private var toolSetupOffered = false
    public var downloadWindow: NSWindow?
    public lazy var downloadModel = WebDownloadWorkspaceModel(state: state)
    private var downloadHotKeyRef: EventHotKeyRef?
    private var downloadHotKeyEventHandler: EventHandlerRef?
    private let successToast = SuccessStatusToast()
    public var welcome: NSWindow?
    public var monitor: DragStagingMonitor!
    public var wheel: SpatialSelectionWheelController!
    public var windowManagement: AppWindowManager!
    private var hasFinishedLaunching = false
    // AppKit delivers files opened at launch before applicationDidFinishLaunching, when the wheel is not set up yet.
    private var openRequestsBeforeLaunch: [[URL]] = []

    private lazy var services = FinderServicesIntegration { [weak self] urls in
        self?.application(NSApp, open: urls)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let storedTheme = UserDefaults.standard.string(forKey: "colorTheme")
        if storedTheme != ColorTheme.resolve(storedTheme).rawValue {
            UserDefaults.standard.set(ColorTheme.resolve(storedTheme).rawValue, forKey: "colorTheme")
        }
        FileveroAppearanceTheme.apply()
        // Before Services register, so they never record a Downloads or disk-image path.
        if ApplicationsFolderMover.offerMoveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        UserDefaults.standard.register(defaults: [
            "enabled": true, "reveal": true, "sound": true, "convertKey": "shift", "toolsKey": "command",
            "actionsKey": "control", "wheelScale": 1.0, "windowManagementEnabled": true
        ])

        let (mainMenu, appMenu, statusBarMenu) = buildMenus()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = ApplicationBrandArtwork.menuIcon()
        statusItem.menu = statusBarMenu
        if let button = statusItem.button {
            let dropZone = StatusBarDropZoneView(frame: button.bounds)
            dropZone.autoresizingMask = [.width, .height]
            dropZone.onDrop = { [weak self] urls, point in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.wheel.show(inputs: urls, mode: .tools, at: point, keyboard: true)
            }
            button.addSubview(dropZone)
        }
        statusBarMenu.delegate = self
        appMenu.delegate = self
        L10n.localize(mainMenu)
        L10n.localize(statusBarMenu)

        NotificationCenter.default.publisher(for: .fileveroLanguageChanged)
            .sink { _ in
                L10n.localize(NSApp.mainMenu)
                L10n.localize(statusBarMenu)
                L10n.updateWindowTitles()
            }
            .store(in: &updateSubscriptions)

        state.$working
            .sink { [weak self] working in
                guard let self else { return }
                self.updater.setBusy(working || self.toolSetupWorking)
            }
            .store(in: &updateSubscriptions)

        updater.$availableVersion
            .sink { [weak self] version in
                guard let self else { return }
                let checkTitle = version.map { "Update to \($0)…" } ?? "Check for Updates…"
                for menu in [appMenu, statusBarMenu] {
                    menu.items.first { $0.action == #selector(self.checkForUpdates) }.map {
                        L10n.menuTitle($0, source: checkTitle)
                    }
                }
                self.statusItem.button?.image = ApplicationBrandArtwork.menuIcon(updateAvailable: version != nil)
            }
            .store(in: &updateSubscriptions)

        for notifName in [
            NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification
        ] {
            NotificationCenter.default.publisher(for: notifName)
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.showProgressToast() }
                }
                .store(in: &updateSubscriptions)
        }

        updater.start()

        NotificationCenter.default.publisher(for: .showUpdateConnection)
            .sink { [weak self] _ in self?.showUpdateConnection() }
            .store(in: &updateSubscriptions)

        NotificationCenter.default.publisher(for: .showToolSetup)
            .sink { [weak self] _ in self?.showToolSetup() }
            .store(in: &updateSubscriptions)

        wheel = SpatialSelectionWheelController(state: state)
        monitor = DragStagingMonitor(
            onEnd: { [weak self] in self?.wheel.endDrag() },
            onActivate: { [weak self] urls, mode, point in self?.wheel.show(inputs: urls, mode: mode, at: point) }
        )

        windowManagement = AppWindowManager(fileWheelIsVisible: { [weak self] in
            self?.wheel.panel?.isVisible == true
        })
        windowManagement.onNotice = { noticeText in
            let alert = NSAlert()
            alert.messageText = "Window arrangement"
            alert.informativeText = noticeText
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        state.onOpenWheel = { [weak self] in
            self?.wheel.show(inputs: self?.state.inputs ?? [], mode: .tools, at: NSEvent.mouseLocation, keyboard: true)
        }
        state.onWebDownload = { [weak self] url, mode in self?.showWebDownload(url, mode: mode) }
        state.onWebDrop = { [weak self] urls in
            self?.wheel.show(inputs: urls, mode: .tools, at: NSEvent.mouseLocation, keyboard: true)
        }

        registerDownloadShortcut()

        homeKeyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.home, self.home?.isKeyWindow == true else { return event }
            return self.state.handleHomeKey(event, window: self.home!) ? nil : event
        }

        state.onChooseFiles = { [weak self] in self?.chooseFiles() }
        state.onSettings = { [weak self] in self?.showSettings() }
        state.onShowTool = { [weak self] toolKind in self?.showTool(toolKind) }
        state.onEPUBOptions = { [weak self] in
            guard let self else { return }
            let window = self.makeStandardWindow(
                title: "Convert to EPUB",
                size: NSSize(width: 530, height: 390),
                view: EbookOptionsInspectorView(state: self.state, inputs: self.state.inputs)
            )
            self.state.retainToolWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        state.onJobStarted = { [weak self] in
            self?.successToast.dismiss()
            self?.showProgressToast()
        }
        state.onSuccess = { [weak self] notice in
            self?.progressToast.dismiss()
            self?.successToast.show(notice)
        }

        let launchedAsLoginItem = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue ?? false

        if !launchedAsLoginItem, !CommandLine.arguments.contains("--background") {
            if UserDefaults.standard.bool(forKey: "hasCompletedWelcome") {
                showHome()
            } else {
                showWelcome()
            }
        }

        UserDefaults.standard.set(true, forKey: "hasOpened")

        if let idx = CommandLine.arguments.firstIndex(of: "--open"), idx + 1 < CommandLine.arguments.count {
            state.inputs = CommandLine.arguments[(idx + 1)...].map { URL(fileURLWithPath: $0) }
            showHome()
        }

        hasFinishedLaunching = true
        let pendingOpens = openRequestsBeforeLaunch
        openRequestsBeforeLaunch = []
        for urls in pendingOpens { application(NSApp, open: urls) }
    }

    @objc public func showLibrary() {
        showHome()
        state.libraryVisible = true
        state.selectedHistoryID = state.history.first?.id
    }

    @objc public func findInLibrary() {
        showLibrary()
        state.libraryFocusRequest += 1
    }

    @objc public func showHome() {
        state.libraryVisible = false
        progressToast.dismiss()

        if home == nil {
            home = makeStandardWindow(
                title: "Filevero",
                size: NSSize(width: 1120, height: 740),
                view: PrimaryWorkspaceView(state: state, updater: updater)
            )
        }
        home?.contentMinSize = NSSize(width: 1000, height: 680)
        home?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !toolSetupOffered,
           Bundle.main.object(forInfoDictionaryKey: "FileveroExternalTools") as? Bool == true,
           !ExternalToolSetup.status.ready
        {
            showToolSetup()
        }
    }

    @objc public func showToolSetup() {
        toolSetupOffered = true
        if toolSetupWindow == nil {
            let coordinator = ExternalToolSetupCoordinator()
            toolSetupModel = coordinator
            coordinator.onWorkingChange = { [weak self] working in
                guard let self else { return }
                self.toolSetupWorking = working
                self.toolSetupWindow?.standardWindowButton(.closeButton)?.isEnabled = !working
                self.updater.setBusy(working || self.state.working)
            }
            toolSetupWindow = makeStandardWindow(
                title: "Set up Filevero tools",
                size: NSSize(width: 646, height: 690),
                view: ExternalToolSetupView(
                    model: coordinator,
                    onDone: { [weak self] in
                        guard ExternalToolSetup.status.ready else { return }
                        UserDefaults.standard.set(true, forKey: "hasCompletedWelcome")
                        self?.toolSetupWindow?.close()
                        self?.showHome()
                    }
                )
            )
        }
        toolSetupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func showDownloadLink() {
        showWebDownload(WebLinkPayload.clipboardLink(), mode: .video)
    }

    public func showWebDownload(_ url: URL?, mode: WebDownloadMode) {
        if downloadWindow == nil {
            downloadWindow = makeLiquidToolWindow(
                title: "Download from the web",
                size: NSSize(width: 660, height: 680),
                view: WebDownloadWorkspaceView(model: downloadModel, state: state)
            )
            downloadWindow?.contentMinSize = NSSize(width: 620, height: 520)
            downloadModel.onUseFiles = { [weak self] in
                guard let self else { return }
                self.state.inputs = self.downloadModel.completed
                self.downloadWindow?.close()
                self.showHome()
            }
        }
        downloadModel.open(url, mode: mode)
        downloadWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func registerDownloadShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptrContext = Unmanaged.passUnretained(self).toOpaque()

        let installedStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let del = Unmanaged<FileveroAppDelegate>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in del.showDownloadLink() }
                return noErr
            },
            1,
            &spec,
            ptrContext,
            &downloadHotKeyEventHandler
        )

        if installedStatus == noErr {
            let keyIdentifier = EventHotKeyID(signature: 0x5447_4E44, id: 1)
            state.webShortcutAvailable = RegisterEventHotKey(
                UInt32(kVK_ANSI_D),
                UInt32(controlKey | shiftKey),
                keyIdentifier,
                GetApplicationEventTarget(),
                0,
                &downloadHotKeyRef
            ) == noErr
        }
        downloadModel.shortcutAvailable = state.webShortcutAvailable
    }

    public func applicationWillTerminate(_ notification: Notification) {
        state.flushPendingState()
        windowManagement?.stop()
        if let hotKey = downloadHotKeyRef {
            UnregisterEventHotKey(hotKey)
        }
        if let handler = downloadHotKeyEventHandler {
            RemoveEventHandler(handler)
        }
    }

    @objc public func chooseFiles() {
        guard !state.working else { return }
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true
        openPanel.prompt = L10n.text("Choose Files")
        if openPanel.runModal() == .OK {
            state.inputs = openPanel.urls
            showHome()
        }
    }

    @objc public func showSettings() {
        presentSettingsWorkspace()
    }

    public func presentSettings(section: SettingsSection? = nil) {
        presentSettingsWorkspace(section: section)
    }

    public func presentSettingsWorkspace(section: SettingsSection? = nil) {
        if settings == nil {
            settings = makeStandardWindow(
                title: "Filevero Settings",
                size: NSSize(width: 860, height: 700),
                view: SettingsWorkspaceViews(updater: updater, initialSection: section ?? .general)
            )
        } else if section == .updates {
            NotificationCenter.default.post(name: .showUpdateSettings, object: nil)
        } else if section == .about {
            NotificationCenter.default.post(name: .showAboutSettings, object: nil)
        }

        settings?.contentMinSize = NSSize(width: 790, height: 590)
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func showWelcome() {
        if welcome == nil {
            let panel = LiquidGlassToolPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.borderless, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.text("Welcome to Filevero")
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false

            let welcomeView = OnboardingWelcomeView(
                onDone: { [weak self] in self?.finishWelcome() },
                onClose: { [weak self] in self?.finishWelcome() },
                onMinimize: { [weak self] in self?.welcome?.orderOut(nil) }
            )
            panel.contentView = NSHostingView(rootView: welcomeView.fileveroLanguage())
            panel.center()
            welcome = panel
        }
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishWelcome() {
        welcome?.close()
        welcome = nil
        if ExternalToolSetup.status.ready {
            UserDefaults.standard.set(true, forKey: "hasCompletedWelcome")
        }
        showHome()
        if !ExternalToolSetup.status.ready {
            showToolSetup()
        }
    }

    @objc public func toggleEnabled(_ sender: NSMenuItem) {
        let currentValue = !UserDefaults.standard.bool(forKey: "enabled")
        UserDefaults.standard.set(currentValue, forKey: "enabled")
        sender.state = currentValue ? .on : .off
    }

    @objc public func checkForUpdates() {
        if updater.isConfigured {
            updater.checkForUpdates()
        } else {
            showUpdateConnection()
        }
    }

    @objc public func showUpdateConnection() {
        if updateConnection == nil {
            updateConnection = makeStandardWindow(
                title: "Filevero Update Connection",
                size: NSSize(width: 620, height: 720),
                view: AppUpdateConnectionView(updater: updater)
            )
        }
        updateConnection?.contentMinSize = NSSize(width: 560, height: 570)
        updateConnection?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func quit() {
        NSApp.terminate(nil)
    }

    public func showProgressToast() {
        guard state.working else { return }
        if NSApp.isActive &&
            (state.toolWindows.contains(where: { $0.isVisible && !$0.isMiniaturized }) ||
             (home?.isVisible == true && home?.isMiniaturized == false) ||
             downloadWindow?.isVisible == true)
        {
            progressToast.dismiss()
            return
        }
        progressToast.show(state: state)
    }

    public func showTool(_ kind: ToolKind) {
        progressToast.dismiss()

        if kind == .readQRCode {
            let window = makeLiquidToolWindow(
                title: kind.title,
                size: NSSize(width: 590, height: 620),
                view: BarcodeScannerView(inputs: state.inputs, onSuccess: { [weak self] in self?.state.reportSuccess($0) })
            )
            state.retainToolWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if [.renameFiles, .organizeFiles, .findDuplicates].contains(kind) {
            let window = makeLiquidToolWindow(
                title: kind.title,
                size: NSSize(width: 680, height: 640),
                view: FolderOrganizationViews(state: state, tool: kind)
            )
            state.retainToolWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editorView = ToolWorkbench(state: state, tool: kind)
        let hasPreviewPane = [
            ToolKind.editImage, .annotateImage, .cropImage, .frameImage, .redactImage, .createCollage, .cropVideo,
            .trimVideo, .changeVideoSpeed, .splitVideo, .videoSnapshots, .redactVideo, .trimAudio, .normalizeAudio,
            .audioChannels, .redactAudio, .audioToVideo, .removeBackground
        ].contains(kind)

        let window = makeLiquidToolWindow(
            title: FeatureCatalog.toolNames[kind] ?? kind.title,
            size: NSSize(
                width: hasPreviewPane ? 1000 : (kind == .organizePDF ? 780 : 600),
                height: kind == .compress ? 630 : 760
            ),
            view: editorView
        )
        state.retainToolWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard hasFinishedLaunching else {
            openRequestsBeforeLaunch.append(urls)
            return
        }
        if let webURL = urls.first(where: { !$0.isFileURL }),
           let validURL = try? WebDownloadEngine.link(webURL.absoluteString)
        {
            showWebDownload(validURL, mode: .video)
        } else {
            state.inputs = urls
            showHome()
            state.onOpenWheel?()
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.working || toolSetupWorking || state.movingFiles else { return .terminateNow }
        if state.working || toolSetupWorking {
            guard systemSessionIsEnding || confirmQuitWhileWorking() else { return .terminateCancel }
            state.cancelAll()
            toolSetupModel?.cancel()
        }
        // Give cancelled work a moment to stop its tools and remove staging files, and file moves a moment
        // to finish, without holding up the quit.
        let deadline = Date().addingTimeInterval(5)
        Task { [weak self] in
            while let self, self.state.working || self.toolSetupWorking || self.state.movingFiles, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var systemSessionIsEnding: Bool {
        guard
            let reason = NSAppleEventManager.shared().currentAppleEvent?
                .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown].contains { OSType($0) == reason }
    }

    private func confirmQuitWhileWorking() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.text("Filevero is still working")
        alert.informativeText = L10n.text("Quitting stops the current operation. Unfinished files are not saved.")
        alert.addButton(withTitle: L10n.text("Quit Anyway"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome()
        return true
    }

    public func makeStandardWindow<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        L10n.windowTitle(win, source: title)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.backgroundColor = ThemeTokenPalette.nsCanvas()
        win.contentView = NSHostingView(rootView: view.fileveroLanguage())
        win.center()
        fitWindowToScreen(win)
        return win
    }

    public func makeLiquidToolWindow<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let win = LiquidGlassToolPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        L10n.windowTitle(win, source: title)
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = false
        win.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: view.fileveroLanguage())
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 24
        hosting.layer?.masksToBounds = true
        win.contentView = hosting
        win.center()
        fitWindowToScreen(win)
        return win
    }

    private func fitWindowToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 16, dy: 16) else { return }
        let clampedSize = NSSize(
            width: min(window.frame.width, visible.width),
            height: min(window.frame.height, visible.height)
        )
        window.setFrame(
            NSRect(
                x: visible.midX - clampedSize.width / 2,
                y: visible.midY - clampedSize.height / 2,
                width: clampedSize.width,
                height: clampedSize.height
            ),
            display: false
        )
    }
}

extension FileveroAppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return !updater.isConfigured || (updater.canCheckForUpdates && !updater.isBusy)
        }
        if menuItem.action == #selector(quit) {
            return !state.working
        }
        return true
    }
}

// MARK: - Finder Services Integration

public final class FinderServicesIntegration: NSObject {
    private let openCallback: ([URL]) -> Void
    public init(open: @escaping ([URL]) -> Void) {
        self.openCallback = open
    }

    @objc public func openFiles(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were received." as NSString
            return
        }
        openCallback(urls)
    }
}

public final class LiquidGlassToolPanel: NSPanel {
    override public var canBecomeKey: Bool { true }
}

// MARK: - Backwards Compatibility Bridges
public typealias AppDelegate = FileveroAppDelegate
public typealias FinderServices = FinderServicesIntegration
public typealias ToolPanel = LiquidGlassToolPanel
