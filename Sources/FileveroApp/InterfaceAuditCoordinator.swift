import AppKit
import FileveroCore
import FileveroUpdates
import PDFKit
import SwiftUI

// MARK: - Interface Audit Configuration & Options

public struct InterfaceAuditOptions {
    public static let scenes: [String] = [
        "welcome.1", "welcome.2", "welcome.3", "welcome.4", "welcome.5", "welcome.6",
        "home.empty", "home.selected", "home.queue", "home.workflows", "workflow.editor",
        "home.output-names", "library", "settings.general", "settings.formats",
        "settings.video", "settings.folders", "settings.updates", "wheel.pdf-multiple",
        "wheel.window", "editor.crop-image", "editor.annotate-image", "editor.frame-image",
        "editor.recognize-text", "home.actions", "organize.rename", "editor.watermark"
    ]

    public var output: URL
    public var scenes: [String] = Self.scenes
    public var appearances: [String] = ["light", "dark"]
    public var languages: [String] = ["en", "tr"]
    public var themes: [String] = [ColorTheme.aurora.rawValue]
    public var reduceTransparency: Bool = false
    public var hold: Bool = false

    public init(arguments: [String]) throws {
        guard let startIndex = arguments.firstIndex(of: "--ui-audit"),
              startIndex + 1 < arguments.count,
              !arguments[startIndex + 1].hasPrefix("--")
        else {
            throw InterfaceAuditError(
                "Use --ui-audit OUTPUT [--scenes scene,...] [--appearance light|dark|both] [--language en|tr|both] [--theme NAME|all] [--reduce-transparency] [--hold]"
            )
        }

        output = URL(fileURLWithPath: arguments[startIndex + 1], isDirectory: true).standardizedFileURL
        var cursor = startIndex + 2

        while cursor < arguments.count {
            let key = arguments[cursor]
            cursor += 1

            if key == "--hold" {
                hold = true
                continue
            }
            if key == "--reduce-transparency" {
                reduceTransparency = true
                continue
            }

            guard cursor < arguments.count else {
                throw InterfaceAuditError("Missing value for " + key)
            }
            let value = arguments[cursor]
            cursor += 1

            switch key {
            case "--scenes":
                scenes = value.split(separator: ",").map(String.init)
                guard !scenes.isEmpty,
                      Set(scenes).count == scenes.count,
                      scenes.allSatisfy(Self.scenes.contains)
                else {
                    throw InterfaceAuditError("Unknown or repeated audit scene. Supported: " + Self.scenes.joined(separator: ","))
                }
            case "--appearance":
                guard ["light", "dark", "both"].contains(value) else {
                    throw InterfaceAuditError("Appearance must be light, dark or both")
                }
                appearances = value == "both" ? ["light", "dark"] : [value]
            case "--language":
                guard ["en", "tr", "both"].contains(value) else {
                    throw InterfaceAuditError("Language must be en, tr or both")
                }
                languages = value == "both" ? ["en", "tr"] : [value]
            case "--theme":
                guard value == "all" || ColorTheme(rawValue: value) != nil else {
                    throw InterfaceAuditError("Theme must be all or one of " + ColorTheme.allCases.map(\.rawValue).joined(separator: ","))
                }
                themes = value == "all" ? ColorTheme.allCases.map(\.rawValue) : [value]
            default:
                throw InterfaceAuditError("Unknown audit argument: " + key)
            }
        }
    }
}

// MARK: - InterfaceAuditCoordinator: Headless Quality Verification Orchestrator

@MainActor
public final class InterfaceAuditCoordinator: NSObject, NSApplicationDelegate {
    public let options: InterfaceAuditOptions
    private var window: NSWindow?
    private var auditRecords: [[String: Any]] = []
    private var fixtureRootDirectory: URL?
    private var preferenceSuites: Set<String> = []
    private var observedPreferencesMap: [String: String] = [:]
    private var activeThemeName: String = ColorTheme.aurora.rawValue
    private var originalArgumentDomain: [String: Any]?
    private var isOutputPrepared: Bool = false
    private var hasFinishedExecution: Bool = false
    private var isAuditSuccessful: Bool = false
    private var validatorChecks: [String] = []
    private var fixtureFiles: [String: URL] = [:]

    public init(options: InterfaceAuditOptions) {
        self.options = options
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            do {
                try await runAuditPipeline()
            } catch {
                auditRecords.append([
                    "scene": "setup",
                    "status": "failed",
                    "issues": [error.localizedDescription]
                ])
            }

            let expectedCaptureCount = options.scenes.count * options.appearances.count * options.languages.count * options.themes.count
            isAuditSuccessful = auditRecords.count == expectedCaptureCount &&
                auditRecords.allSatisfy { ($0["status"] as? String) == "captured" }

            if isOutputPrepared {
                do {
                    try generateManifest()
                } catch {
                    isAuditSuccessful = false
                    fputs("UI audit manifest could not be saved.\n", stderr)
                }
            } else {
                fputs("UI audit output was not prepared; no manifest was written.\n", stderr)
            }

            hasFinishedExecution = true
            print("UI_AUDIT " + (isAuditSuccessful ? "PASS" : "FAIL") + " " + options.output.path)
            if !options.hold || window == nil {
                NSApp.terminate(nil)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        hasFinishedExecution
    }

    public func applicationWillTerminate(_ notification: Notification) {
        window?.close()
        for suite in preferenceSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        preferenceSuites.removeAll()

        if let original = originalArgumentDomain {
            UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        if let root = fixtureRootDirectory {
            try? FileManager.default.removeItem(at: root)
        }
        if !isAuditSuccessful {
            exit(1)
        }
    }

    private func prepareOutputDirectory() throws {
        let fileManager = FileManager.default
        let markerFile = options.output.appendingPathComponent(".filevero-ui-audit")
        if fileManager.fileExists(atPath: options.output.path), !fileManager.fileExists(atPath: markerFile.path) {
            let entries = try fileManager.contentsOfDirectory(atPath: options.output.path)
            guard entries.isEmpty else {
                throw InterfaceAuditError("Choose an empty output directory; UI audit will not overwrite unrelated files.")
            }
        }
        try fileManager.createDirectory(at: options.output, withIntermediateDirectories: true)
        try Data("Filevero UI audit v1\n".utf8).write(to: markerFile, options: .atomic)
        isOutputPrepared = true
    }

    private func createSyntheticFixtures() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Filevero-UIAudit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fixtureRootDirectory = tempDir

        let sampleImageURL = tempDir.appendingPathComponent("İstanbul – uzun dosya adı ve görsel örneği 🧭.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 640,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 640 * 4,
            bitsPerPixel: 32
        )!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.82, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 400)).fill()
        NSColor(calibratedRed: 0.78, green: 0.72, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 50, width: 300, height: 230), xRadius: 24, yRadius: 24).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw InterfaceAuditError("Image fixture could not be generated")
        }
        try pngData.write(to: sampleImageURL)

        let sampleTextURL = tempDir.appendingPathComponent("Türkçe notlar – kaynak dosya.txt")
        try "Filevero audit fixture · ıİşğü 🧭\nOriginal files stay intact.".write(to: sampleTextURL, atomically: true, encoding: .utf8)

        for number in 1...2 {
            let pdfDoc = PDFDocument()
            for _ in 0..<2 {
                guard let page = PDFPage(image: NSImage(data: pngData)!) else {
                    throw InterfaceAuditError("PDF fixture could not be generated")
                }
                pdfDoc.insert(page, at: pdfDoc.pageCount)
            }
            let pdfPath = tempDir.appendingPathComponent("Örnek belge \(number).pdf")
            guard pdfDoc.write(to: pdfPath) else {
                throw InterfaceAuditError("PDF fixture could not be saved")
            }
            fixtureFiles["pdf\(number)"] = pdfPath
        }

        fixtureFiles["image"] = sampleImageURL
        fixtureFiles["text"] = sampleTextURL
        fixtureFiles["missing"] = tempDir.appendingPathComponent("Missing original.png")
    }

    private func runAuditPipeline() async throws {
        try prepareOutputDirectory()
        validatorChecks = try InterfaceAuditChecks.run()
        validatorChecks += try InterfaceAuditChecks.redactionPreviews(at: options.output.appendingPathComponent("redaction-preview"))

        originalArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        try createSyntheticFixtures()

        for theme in options.themes {
            for language in options.languages {
                for appearance in options.appearances {
                    for scene in options.scenes {
                        activeThemeName = theme
                        window?.contentView = nil
                        window?.close()
                        window = nil

                        let suiteName = "Filevero.UIAudit." + UUID().uuidString
                        preferenceSuites.insert(suiteName)
                        guard let defaults = UserDefaults(suiteName: suiteName) else {
                            throw InterfaceAuditError("Isolated audit preferences could not be created")
                        }

                        var arguments = originalArgumentDomain ?? [:]
                        arguments["appLanguage"] = language
                        arguments["appAppearance"] = appearance
                        arguments["reduceAnimations"] = true
                        arguments["soundsAndHapticsEnabled"] = false
                        arguments["sound"] = false
                        arguments["reveal"] = false
                        arguments["colorTheme"] = theme
                        arguments["reduceTransparency"] = options.reduceTransparency

                        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                        defaults.set(language, forKey: "appLanguage")
                        defaults.set(appearance, forKey: "appAppearance")
                        defaults.set(true, forKey: "reduceAnimations")
                        defaults.set(theme, forKey: "colorTheme")
                        defaults.set(options.reduceTransparency, forKey: "reduceTransparency")

                        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        observedPreferencesMap = [:]

                        do {
                            try await captureScene(scene: scene, appearance: appearance, language: language, defaults: defaults)
                        } catch {
                            auditRecords.append([
                                "scene": scene,
                                "appearance": appearance,
                                "language": language,
                                "theme": theme,
                                "status": "failed",
                                "issues": [error.localizedDescription]
                            ])
                        }
                    }
                }
            }
        }
    }

    private func captureScene(scene: String, appearance: String, language: String, defaults: UserDefaults) async throws {
        window?.close()
        window = nil

        let state = AppSessionController(defaults: defaults)
        let layoutRecorder = InterfaceAuditLayout()
        let updater = SparkleUpdateCoordinator()

        let image = fixtureFiles["image"]!
        let text = fixtureFiles["text"]!
        let pdf = fixtureFiles["pdf1"]!

        if scene == "home.selected" || scene.hasPrefix("editor.") {
            state.inputs = [image]
        }

        if scene == "home.queue" {
            var queue = JobQueueState()
            queue.enqueue([image, text, pdf, fixtureFiles["pdf2"]!, fixtureFiles["missing"]!], operation: .convert("pdf"), options: .init())
            let ids = queue.jobs.map(\.id)
            queue.update(ids[0], to: .done([image.deletingPathExtension().appendingPathExtension("pdf")]))
            queue.update(ids[1], to: .failed("This file could not be read."))
            queue.update(ids[2], to: .running)
            queue.update(ids[4], to: .interrupted)
            state.queue = queue
        }

        if scene == "library" {
            state.history = [
                (image, "Convert to PNG"),
                (text, "Pasted text"),
                (pdf, "Merge PDFs"),
                (fixtureFiles["missing"]!, "Missing original")
            ].enumerated().map { index, item in
                JobRecord(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                    title: item.1,
                    inputs: [],
                    outputs: [item.0.path],
                    date: Date(timeIntervalSince1970: 1_767_225_600)
                )
            }
            state.libraryVisible = true
        }

        let isEditor = scene.hasPrefix("editor.")
        let sceneView: AnyView
        let sceneDimensions: NSSize

        switch scene {
        case let val where val.hasPrefix("welcome."):
            let pageIndex = (Int(val.split(separator: ".").last ?? "1") ?? 1) - 1
            sceneView = AnyView(OnboardingWelcomeView(onDone: {}, onClose: {}, onMinimize: {}, initialPage: pageIndex))
            sceneDimensions = NSSize(width: 760, height: 520)

        case "home.workflows":
            state.inputs = [image]
            let store = WorkflowPipelineStore(defaults: defaults)
            store.save(WorkflowPipeline(name: "Görselleri web için hazırla", steps: [.resize(maxDimension: 1600), .convert(format: "webp"), .removeMetadata]))
            store.save(WorkflowPipeline(name: "PDF arşivi", steps: [.convert(format: "pdf"), .compress(preset: "balanced")]))
            store.save(WorkflowPipeline(name: "Yalnızca belgeler", steps: [.convert(format: "txt")]))
            sceneView = AnyView(PrimaryWorkspaceView(state: state, updater: updater, workflows: store, actionSection: 3))
            sceneDimensions = NSSize(width: 1000, height: 680)

        case "home.output-names":
            defaults.set("Rapor", forKey: OutputNamePreference.key)
            let conflictFile = image.deletingLastPathComponent().appendingPathComponent("Rapor.jpg")
            if !FileManager.default.fileExists(atPath: conflictFile.path) {
                try Data("taken".utf8).write(to: conflictFile)
            }
            sceneView = AnyView(
                OutputNameInspectorPanel(inputs: [image, fixtureFiles["text"]!, pdf], formats: ["jpg", "png", "pdf"], expanded: true)
                    .padding(18)
                    .frame(width: 284, height: 360, alignment: .topLeading)
                    .background(.regularMaterial)
            )
            sceneDimensions = NSSize(width: 284, height: 360)

        case "workflow.editor":
            sceneView = AnyView(
                WorkflowPipelineEditor(
                    workflow: WorkflowPipeline(name: "Görselleri web için hazırla", steps: [.resize(maxDimension: 1600), .convert(format: "webp"), .removeMetadata]),
                    isNew: false,
                    onSave: { _ in },
                    onDelete: { _ in },
                    onCancel: {}
                )
            )
            sceneDimensions = NSSize(width: 460, height: 470)

        case "home.actions":
            state.inputs = [image.deletingLastPathComponent(), image, pdf]
            state.lastMoves = AppliedMoves(
                moves: [FileMove(source: text, destination: text.deletingLastPathComponent().appendingPathComponent("Notlar 1.txt"))],
                createdFolders: [],
                title: "Rename Files",
                date: Date(timeIntervalSince1970: 0)
            )
            sceneView = AnyView(PrimaryWorkspaceView(state: state, updater: updater, actionSection: 2))
            sceneDimensions = NSSize(width: 1000, height: 680)

        case "organize.rename":
            state.inputs = [image, text, pdf]
            var renameOpts = RenameOptions()
            renameOpts.template = "Proje {n}"
            renameOpts.letterCase = .keep
            sceneView = AnyView(FolderOrganizationViews(state: state, tool: .renameFiles, rename: renameOpts))
            sceneDimensions = NSSize(width: 680, height: 600)

        case "home.empty", "home.selected", "home.queue", "library":
            sceneView = AnyView(PrimaryWorkspaceView(state: state, updater: updater))
            sceneDimensions = NSSize(width: 1000, height: 680)

        case "settings.general", "settings.formats", "settings.video", "settings.folders", "settings.updates":
            let section: SettingsSection =
                scene == "settings.formats" || scene == "settings.video"
                ? .formats : scene == "settings.folders" ? .folders : scene == "settings.updates" ? .updates : .general
            if scene == "settings.folders" {
                defaults.set("{n}-{name}", forKey: OutputNamePreference.key)
            }
            sceneView = AnyView(SettingsWorkspaceViews(updater: updater, initialSection: section, initialFormat: scene == "settings.video" ? "mp4" : "jpg"))
            sceneDimensions = NSSize(width: 790, height: 590)

        case "editor.crop-image", "editor.annotate-image", "editor.frame-image", "editor.recognize-text", "editor.watermark":
            let toolKind: ToolKind =
                scene == "editor.crop-image" ? .cropImage :
                scene == "editor.annotate-image" ? .annotateImage :
                scene == "editor.recognize-text" ? .recognizeText :
                scene == "editor.watermark" ? .watermark : .frameImage
            sceneView = AnyView(ToolWorkbench(state: state, tool: toolKind))
            sceneDimensions = NSSize(width: 900, height: 420)

        case "wheel.pdf-multiple", "wheel.window":
            let wheel = SpatialSelectionWheel(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
            let inputs = [fixtureFiles["pdf1"]!, fixtureFiles["pdf2"]!]
            wheel.mode = .tools
            wheel.inputs = inputs
            wheel.opaqueBackdrop = true

            if scene == "wheel.window" {
                wheel.items = WindowPlacement.allCases.map {
                    WheelItem(title: $0.title, symbol: "rectangle", windowPlacement: $0)
                } + WindowCommand.allCases.map {
                    WheelItem(title: $0.title, symbol: $0.symbol, windowCommand: $0)
                }
                wheel.centerTitle = "Arrange window"
            } else {
                wheel.items = FeatureCatalog.tools(for: inputs).map {
                    WheelItem(title: FeatureCatalog.toolNames[$0] ?? $0.title, symbol: FeatureCatalog.toolSymbols[$0], operation: .tool($0))
                }
                wheel.centerTitle = "Tools"
            }

            let hostWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                styleMask: options.hold ? [.borderless] : [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            if options.hold {
                hostWindow.backgroundColor = .clear
                hostWindow.isOpaque = false
                hostWindow.hasShadow = false
            }
            hostWindow.isReleasedWhenClosed = false
            hostWindow.title = "Filevero UI Audit · " + scene
            hostWindow.contentView = wheel
            hostWindow.center()
            hostWindow.makeKeyAndOrderFront(nil)
            window = hostWindow
            NSApp.activate(ignoringOtherApps: true)
            wheel.updateAccessibility()
            try await settleSceneStability(recorder: nil)

            observedPreferencesMap = try await verifyPreferencesRendering(scene: scene, appearance: appearance, language: language, defaults: defaults, view: wheel)
            try saveSceneCapture(
                scene: scene,
                appearance: appearance,
                language: language,
                view: wheel,
                recorder: nil,
                issues: wheel.items.enumerated().flatMap { index, item in
                    wheel.labelAuditIssues(index, title: item.title)
                }
            )
            return

        default:
            throw InterfaceAuditError("Unknown audit scene: \(scene)")
        }

        let rootWithAudit = sceneView.fileveroLanguage().defaultAppStorage(defaults).uiAuditRoot(layoutRecorder)
        let hostWindow: NSWindow

        if isEditor {
            hostWindow = LiquidGlassToolPanel(
                contentRect: NSRect(origin: .zero, size: sceneDimensions),
                styleMask: [.borderless, .closable],
                backing: .buffered,
                defer: false
            )
        } else if options.hold {
            hostWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: sceneDimensions),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            hostWindow.titleVisibility = .hidden
            hostWindow.titlebarAppearsTransparent = true
        } else {
            hostWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: sceneDimensions),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
        }

        hostWindow.isReleasedWhenClosed = false
        hostWindow.title = "Filevero UI Audit · " + scene
        hostWindow.contentView = NSHostingView(rootView: rootWithAudit)
        hostWindow.center()
        window = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        try await settleSceneStability(recorder: isEditor ? layoutRecorder : nil)
        guard let content = hostWindow.contentView else {
            throw InterfaceAuditError("Scene has no content view")
        }

        observedPreferencesMap = try await verifyPreferencesRendering(scene: scene, appearance: appearance, language: language, defaults: defaults, view: content)
        let issues = layoutRecorder.issues(in: content.bounds, editor: isEditor, preview: !["editor.recognize-text", "editor.watermark"].contains(scene))
        try saveSceneCapture(scene: scene, appearance: appearance, language: language, view: content, recorder: layoutRecorder, issues: issues)
    }

    private func settleSceneStability(recorder: InterfaceAuditLayout?) async throws {
        let deadline = Date().addingTimeInterval(12)
        var previousFrames: [String: CGRect] = [:]
        var stableIterations = 0

        while Date() < deadline {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()

            let artworkPending = await DocumentThumbnailCache.shared.pendingCount == 0

            if let recorder {
                if recorder.status.hasPrefix("failed:") {
                    throw InterfaceAuditError(recorder.status)
                }
                if artworkPending, recorder.status == "ready", !recorder.frames.isEmpty, recorder.frames == previousFrames {
                    stableIterations += 1
                } else {
                    stableIterations = 0
                }
                previousFrames = recorder.frames
            } else if artworkPending {
                stableIterations += 1
            } else {
                stableIterations = 0
            }

            if stableIterations >= 3 { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw InterfaceAuditError("Scene readiness/layout did not settle before the audit deadline")
    }

    private func collectAccessibilityTree(_ view: NSView) -> [NSAccessibilityProtocol] {
        var queue: [Any] = [view]
        var collected: [NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()

        while !queue.isEmpty, collected.count < 2000 {
            let item = queue.removeFirst()
            guard let elem = item as? NSAccessibilityProtocol else { continue }
            let id = ObjectIdentifier(elem as AnyObject)
            guard visited.insert(id).inserted else { continue }
            collected.append(elem)
            queue.append(contentsOf: elem.accessibilityChildren() ?? [])
        }
        return collected
    }

    private func collectSubviewsRecursively(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { collectSubviewsRecursively($0) }
    }

    private func extractRenderedSelections(_ view: NSView) -> [String: String] {
        let elements = collectAccessibilityTree(view)
        let subviews = collectSubviewsRecursively(view)
        var map: [String: String] = [:]

        if let languageElem = elements.first(where: { $0.accessibilityIdentifier() == "AppLanguage" }) {
            if let val = languageElem.accessibilityValue() as? String {
                map["languagePicker"] = val
            } else if let title = languageElem.accessibilityTitle() {
                map["languagePicker"] = title
            }
        }

        if let popup = subviews.compactMap({ $0 as? NSPopUpButton }).first(where: {
            ["English", "Türkçe"].contains($0.titleOfSelectedItem ?? "")
        }), let selected = popup.titleOfSelectedItem {
            map["languagePicker"] = selected
        }

        if map["languagePicker"] == nil {
            let diag = elements.filter {
                $0.accessibilityIdentifier() == "AppLanguage" || $0.accessibilityRole() == .popUpButton
            }.prefix(12).map { elem in
                "id=\(elem.accessibilityIdentifier() ?? "nil") role=\(elem.accessibilityRole()?.rawValue ?? "nil") title=\(elem.accessibilityTitle() ?? "nil") label=\(elem.accessibilityLabel() ?? "nil") value=\(String(describing: elem.accessibilityValue()))"
            }
            let native = subviews.compactMap { $0 as? NSPopUpButton }.map {
                "native=\(type(of: $0)) title=\($0.titleOfSelectedItem ?? "nil")"
            }
            map["languagePickerDiagnostics"] = (diag + native).joined(separator: "; ")
        }

        let expectedAppearanceLabels = [L10n.text("System"), L10n.text("Light"), L10n.text("Dark")]
        if let seg = subviews.compactMap({ $0 as? NSSegmentedControl }).first(where: { control in
            control.segmentCount == 3 && (0..<3).map { control.label(forSegment: $0) ?? "" } == expectedAppearanceLabels
        }), seg.selectedSegment >= 0 {
            map["appearancePicker"] = ["system", "light", "dark"][seg.selectedSegment]
        }

        if map["appearancePicker"] == nil {
            for elem in elements {
                let children = (elem.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
                let matches = children.filter { child in
                    expectedAppearanceLabels.contains(child.accessibilityLabel() ?? child.accessibilityTitle() ?? "")
                }
                guard matches.count == 3 else { continue }
                if let chosen = matches.first(where: { ($0.accessibilityValue() as? NSNumber)?.intValue == 1 }),
                   let idx = expectedAppearanceLabels.firstIndex(of: chosen.accessibilityLabel() ?? chosen.accessibilityTitle() ?? "")
                {
                    map["appearancePicker"] = ["system", "light", "dark"][idx]
                    break
                }
            }
        }

        return map
    }

    private func verifyPreferencesRendering(
        scene: String,
        appearance: String,
        language: String,
        defaults: UserDefaults,
        view: NSView
    ) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(3)
        var map: [String: String] = [:]
        var discrepancies: [String] = []

        repeat {
            map = [
                "suiteAppearance": defaults.string(forKey: "appAppearance") ?? "missing",
                "suiteLanguage": defaults.string(forKey: "appLanguage") ?? "missing",
                "standardAppearance": UserDefaults.standard.string(forKey: "appAppearance") ?? "missing",
                "standardLanguage": L10n.language,
                "effectiveAppearance": view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            ]

            discrepancies = []
            for k in ["suiteAppearance", "standardAppearance", "effectiveAppearance"] where map[k] != appearance {
                discrepancies.append(k + "=" + (map[k] ?? "missing"))
            }
            for k in ["suiteLanguage", "standardLanguage"] where map[k] != language {
                discrepancies.append(k + "=" + (map[k] ?? "missing"))
            }

            if scene == "settings.general" {
                map.merge(extractRenderedSelections(view), uniquingKeysWith: { $1 })
                if map["appearancePicker"] != appearance {
                    discrepancies.append("rendered appearance picker=" + (map["appearancePicker"] ?? "unavailable"))
                }
                if map["languagePicker"] != (language == "tr" ? "Türkçe" : "English") {
                    discrepancies.append("rendered language picker=" + (map["languagePicker"] ?? "unavailable"))
                }
            }

            if discrepancies.isEmpty { return map }
            try await Task.sleep(nanoseconds: 40_000_000)
            view.layoutSubtreeIfNeeded()
        } while Date() < deadline

        if let diag = map["languagePickerDiagnostics"] {
            discrepancies.append("language picker diagnostics: " + (diag.isEmpty ? "No native popup or matching accessibility node found" : diag))
        }

        throw InterfaceAuditError("Requested \(appearance)/\(language) preferences did not reach the rendered scene: " + discrepancies.joined(separator: ", "))
    }

    private func saveSceneCapture(
        scene: String,
        appearance: String,
        language: String,
        view: NSView,
        recorder: InterfaceAuditLayout?,
        issues: [String]
    ) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw InterfaceAuditError("Own-view renderer could not allocate a bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let rasterInspection = InterfaceAuditRaster.inspect(rep)
        var totalIssues = issues
        if !rasterInspection.nonBlank {
            totalIssues.append("The own-view render is blank or contains insufficient visible scene content.")
        }

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw InterfaceAuditError("Own-view renderer did not return PNG data")
        }

        let filename = scene + "-" + appearance + "-" + language + (activeThemeName == ColorTheme.aurora.rawValue ? "" : "-" + activeThemeName) + (options.reduceTransparency ? "-opaque" : "") + ".png"
        try png.write(to: options.output.appendingPathComponent(filename), options: .atomic)

        auditRecords.append([
            "scene": scene,
            "appearance": appearance,
            "language": language,
            "theme": activeThemeName,
            "reduceTransparency": options.reduceTransparency,
            "image": filename,
            "status": totalIssues.isEmpty ? "captured" : "failed",
            "issues": totalIssues,
            "frames": recorder?.jsonFrames ?? [:],
            "width": view.bounds.width,
            "height": view.bounds.height,
            "renderedSamples": rasterInspection.samples,
            "visibleSamples": rasterInspection.visibleSamples,
            "sampledColors": rasterInspection.colors,
            "observedPreferences": observedPreferencesMap
        ])
    }

    private func generateManifest() throws {
        guard isOutputPrepared else {
            throw InterfaceAuditError("Output destination did not pass audit preflight")
        }

        let manifestDict: [String: Any] = [
            "schemaVersion": 1,
            "platform": "macOS",
            "passed": isAuditSuccessful,
            "renderTechnique": "own-view-cacheDisplay",
            "validatorChecks": validatorChecks,
            "limitations": [
                "Render proofs do not include live window-server glass or native titlebar chrome; verify those through Computer Use.",
                "Relative history date labels use the run date."
            ],
            "captures": auditRecords
        ]

        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let manifestJSON = try JSONSerialization.data(withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys])
        try manifestJSON.write(to: options.output.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

// MARK: - Backwards Compatibility Bridges
public typealias UIAudit = InterfaceAuditCoordinator
public typealias UIAuditOptions = InterfaceAuditOptions

