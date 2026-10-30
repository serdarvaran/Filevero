import AppKit
import FileveroCore

public enum WheelMode: String, CaseIterable, Sendable {
    case convert, tools, actions
}

public final class WheelPanel: NSPanel {
    override public var canBecomeKey: Bool { true }
}

public enum WebWheelAction: Sendable {
    case download, thumbnail, audio, copy, open
}

public struct WheelItem: Sendable {
    public var title: String
    public var symbol: String? = nil
    public var operation: FileveroCore.Operation? = nil
    public var action: FileAction? = nil
    public var webAction: WebWheelAction? = nil
    public var windowPlacement: WindowPlacement? = nil
    public var windowCommand: WindowCommand? = nil

    public init(
        title: String,
        symbol: String? = nil,
        operation: FileveroCore.Operation? = nil,
        action: FileAction? = nil,
        webAction: WebWheelAction? = nil,
        windowPlacement: WindowPlacement? = nil,
        windowCommand: WindowCommand? = nil
    ) {
        self.title = title
        self.symbol = symbol
        self.operation = operation
        self.action = action
        self.webAction = webAction
        self.windowPlacement = windowPlacement
        self.windowCommand = windowCommand
    }
}

@MainActor
public final class SpatialSelectionWheelController {
    public let state: AppSessionController
    public var panel: NSPanel?
    public var wheel: WheelView?
    public var mode: WheelMode = .convert
    public var inputs: [URL] = []
    public var keyMonitor: Any?
    private var keyboardMode = false
    private var focusObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?

    public init(state: AppSessionController) {
        self.state = state
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.keyboardMode == true { self?.hide() }
            }
        }
    }

    public func show(inputs: [URL], mode: WheelMode, at point: NSPoint, keyboard: Bool = false) {
        guard !inputs.isEmpty, !state.working else { return }
        WheelAcousticFeedback.shared.prepare()
        self.inputs = inputs
        self.mode = mode
        keyboardMode = keyboard

        var items: [WheelItem] = []
        if inputs.first?.isFileURL == false {
            let media = WebMediaDragPayload.parse(urls: inputs.map(\.absoluteString))
            let isVideo = media?.videoURL != nil
            let isPhotos = media?.isInstagramPhotoPost == true

            items = [
                WheelItem(
                    title: isPhotos
                        ? "Download photos…"
                        : isVideo ? "Download video…" : media?.imageURL != nil ? "Download image…" : "Download…",
                    symbol: isPhotos ? "photo.on.rectangle" : isVideo ? "play.rectangle" : "arrow.down.circle",
                    webAction: .download
                )
            ]
            if isVideo, media?.imageURL != nil {
                items.append(WheelItem(title: "Download thumbnail…", symbol: "photo", webAction: .thumbnail))
            }
            if !isPhotos, isVideo || media?.imageURL == nil {
                items.append(WheelItem(title: "Audio MP3…", symbol: "waveform", webAction: .audio))
            }
            items += [
                WheelItem(title: "Copy link", symbol: "link", webAction: .copy),
                WheelItem(title: "Open link", symbol: "safari", webAction: .open),
            ]
        } else {
            switch mode {
            case .convert:
                items = FeatureCatalog.formats(for: inputs).map {
                    WheelItem(title: FormatPreferenceItem.label(for: $0), operation: .convert($0))
                }
            case .tools:
                items = FeatureCatalog.tools(for: inputs).map {
                    WheelItem(
                        title: FeatureCatalog.toolNames[$0] ?? $0.title,
                        symbol: FeatureCatalog.toolSymbols[$0],
                        operation: .tool($0)
                    )
                }
            case .actions:
                items = FileAction.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol, action: $0) }
            }
        }

        let exists = panel?.isVisible ?? false
        let desiredSize = CGFloat(320 * UserDefaults.standard.double(forKey: "wheelScale"))
        if let p = panel, !exists, abs(p.frame.width - desiredSize) > 0.5 {
            p.setContentSize(NSSize(width: desiredSize, height: desiredSize))
            Self.makeCircular(p.contentView, size: desiredSize)
        }

        if panel == nil {
            let size = CGFloat(320 * UserDefaults.standard.double(forKey: "wheelScale"))
            let newPanel = WheelPanel(
                contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            newPanel.level = .statusBar
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.hidesOnDeactivate = false

            let frame = NSRect(x: 0, y: 0, width: size, height: size)
            let view = WheelView(frame: frame)
            view.autoresizingMask = [.width, .height]

            let container: NSView
            // The macOS 26 SDK (Swift 6.2 toolchains) is needed to compile NSGlassEffectView.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: frame)
                glass.contentView = view
                container = glass
            } else {
                container = Self.visualEffectContainer(frame: frame, content: view)
            }
            #else
            container = Self.visualEffectContainer(frame: frame, content: view)
            #endif
            Self.makeCircular(container, size: size)
            newPanel.contentView = container

            view.onSelect = { [weak self] item in self?.apply(item) }
            view.onCancel = { [weak self] in self?.hide() }
            view.onDragInputs = { [weak self] urls in
                guard let self else { return }
                self.show(inputs: urls, mode: self.mode, at: NSEvent.mouseLocation)
            }
            self.panel = newPanel
            self.wheel = view

            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newPanel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if self?.keyboardMode == true { self?.hide() }
                }
            }
        }

        wheel?.centerTitle = inputs.first?.isFileURL == false ? "Web media" : nil
        wheel?.items = items
        wheel?.inputs = inputs
        wheel?.mode = mode
        wheel?.selected = keyboard ? (items.isEmpty ? nil : 0) : nil

        if !exists, let existing = panel {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = min(max(visible.minX + 4, point.x - existing.frame.width / 2), visible.maxX - existing.frame.width - 4)
            let y = min(max(visible.minY + 4, point.y - existing.frame.height / 2), visible.maxY - existing.frame.height - 4)
            existing.setFrameOrigin(NSPoint(x: x, y: y))
        }

        if let effect = panel?.contentView as? NSVisualEffectView {
            effect.state = UserDefaults.standard.string(forKey: "conversionFanTheme") == "metallic" ? .inactive : .active
        }

        if !exists, FileveroMotion.enabled {
            panel?.alphaValue = 0
            panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                panel?.animator().alphaValue = 1
            }
        } else {
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
        }

        wheel?.needsDisplay = true
        wheel?.updateAccessibility()

        if keyboard {
            panel?.makeKey()
            panel?.makeFirstResponder(wheel)
        }

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.panel?.isVisible == true else { return event }
                if self.inputs.first?.isFileURL != false,
                   event.type == .flagsChanged,
                   let next = DragMonitor.mode(for: event.modifierFlags),
                   next != self.mode {
                    self.show(inputs: self.inputs, mode: next, at: NSEvent.mouseLocation, keyboard: keyboard)
                    return nil
                }
                if self.inputs.first?.isFileURL != false,
                   event.type == .keyDown,
                   let next = DragMonitor.mode(for: event.modifierFlags),
                   next != self.mode {
                    self.show(inputs: self.inputs, mode: next, at: NSEvent.mouseLocation, keyboard: keyboard)
                    return nil
                }
                if event.type == .keyDown {
                    self.wheel?.keyDown(with: event)
                    return nil
                }
                return event
            }
        }
    }

    private static func visualEffectContainer(frame: NSRect, content: NSView) -> NSView {
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    private static func makeCircular(_ container: NSView?, size: CGFloat) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = container as? NSGlassEffectView {
            glass.cornerRadius = size / 2
            return
        }
        #endif
        container?.layer?.cornerRadius = size / 2
    }

    public func apply(_ item: WheelItem) {
        hide()
        if let action = item.webAction, let media = WebMediaDragPayload.parse(urls: inputs.map(\.absoluteString)) {
            switch action {
            case .download:
                state.onWebDownload?(
                    media.primaryURL,
                    media.isInstagramPhotoPost || (media.videoURL == nil && media.imageURL != nil) ? .original : .video
                )
            case .thumbnail:
                if let image = media.imageURL { state.onWebDownload?(image, .original) }
            case .audio:
                state.onWebDownload?(media.videoURL ?? media.primaryURL, .audioMP3)
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([media.primaryURL as NSURL])
            case .open:
                NSWorkspace.shared.open(media.primaryURL)
            }
            return
        }
        state.inputs = inputs
        if let action = item.action { state.perform(action) }
        if let operation = item.operation { state.select(operation) }
    }

    public func hide() {
        keyboardMode = false
        panel?.orderOut(nil)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    public func endDrag() {
        if !keyboardMode { hide() }
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }
}

// Backward-compatibility alias
public typealias WheelController = SpatialSelectionWheelController
public typealias SpatialSelectionWheel = WheelView
public typealias DragStagingMonitor = DragMonitor

public final class WheelView: NSView {
    public var opaqueBackdrop = false
    public var items: [WheelItem] = [] {
        didSet { labelLayouts.removeAll() }
    }
    private var labelLayouts: [Int: WheelSegmentLayout.Content] = [:]
    private var labelBounds = NSRect.zero
    public var inputs: [URL] = []
    public var mode: WheelMode = .convert
    public var centerTitle: String?

    public var selected: Int? {
        didSet {
            guard oldValue != selected else { return }
            needsDisplay = true
            if selected != nil { WheelAcousticFeedback.shared.selectionChanged() }
        }
    }

    public var onSelect: ((WheelItem) -> Void)?
    public var onCancel: (() -> Void)?
    public var onDragInputs: (([URL]) -> Void)?
    private var trackingArea: NSTrackingArea?

    override public var acceptsFirstResponder: Bool { true }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(WebDownloadDropPayload.pasteboardTypes)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Filevero \(mode.rawValue) palette")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let newArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        trackingArea = newArea
        addTrackingArea(newArea)
        super.updateTrackingAreas()
    }

    public var geometry: WheelSpatialGeometry { WheelSpatialGeometry(bounds: bounds, count: items.count) }
    public var center: NSPoint { geometry.center }
    public var radius: CGFloat { geometry.radius }
    public var inner: CGFloat { geometry.inner }

    public func petal(_ index: Int) -> NSBezierPath { geometry.petal(index) }

    override public func draw(_ dirtyRect: NSRect) {
        if labelBounds != bounds {
            labelLayouts.removeAll()
            labelBounds = bounds
        }
        if labelLayouts.count != items.count { layoutLabels() }

        let solid = UserDefaults.standard.string(forKey: "conversionFanTheme") == "metallic"
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = geometry.scale
        let surface = NSColor.white.withAlphaComponent(solid ? 0.08 : isDark ? 0.10 : 0.45)
        let edge = NSColor.separatorColor.withAlphaComponent(0.35)
        let backdrop = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))

        if solid {
            (ThemeTokenPalette.nsColor(from: ThemeTokenPalette.currentTheme.palette.canvasDark).blended(
                withFraction: 0.15, of: ThemeTokenPalette.primaryAccentNS) ?? .windowBackgroundColor).setFill()
            backdrop.fill()
        } else if FileveroTransparency.reduced {
            NSColor.windowBackgroundColor.setFill()
            backdrop.fill()
        } else if opaqueBackdrop {
            ThemeTokenPalette.canvasBackgroundNS().setFill()
            backdrop.fill()
        }

        NSColor.white.withAlphaComponent(solid || isDark ? 0.14 : 0.55).setStroke()
        backdrop.lineWidth = 0.8
        backdrop.stroke()

        for (i, item) in items.enumerated() {
            let path = petal(i)
            if selected == i,
               let gradient = NSGradient(starting: ThemeTokenPalette.primaryAccentNS, ending: ThemeTokenPalette.secondaryAccentNS) {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = ThemeTokenPalette.primaryAccentNS.withAlphaComponent(0.45)
                glow.shadowBlurRadius = 10
                glow.set()
                ThemeTokenPalette.primaryAccentNS.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                gradient.draw(in: path, angle: 80)
            } else {
                surface.setFill()
                path.fill()
                edge.setStroke()
                path.lineWidth = 0.6
                path.stroke()
            }

            let foreground = selected == i ? ThemeTokenPalette.onAccentTextNS : solid ? NSColor.white : NSColor.labelColor
            let source = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.title) }
            guard let layout = labelLayouts[i] else { continue }

            if let placement = item.windowPlacement, let slot = layout.iconRect {
                WindowPlacementGlyph.draw(placement, in: slot, color: foreground)
            } else if let source, let slot = layout.iconRect {
                let image = source.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? source
                image.isTemplate = false
                let fit = min(slot.width / max(1, image.size.width), slot.height / max(1, image.size.height))
                let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
                let rect = NSRect(
                    x: slot.midX - size.width / 2,
                    y: slot.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                image.draw(in: rect)
            }
            WheelSegmentLayout.draw(layout, color: foreground)
        }

        let disc = geometry.disc
        surface.setFill()
        disc.fill()
        edge.setStroke()
        disc.lineWidth = 0.6
        disc.stroke()

        // The centre names the hovered option, otherwise the wheel itself.
        let title = selected.flatMap { items.indices.contains($0) ? items[$0].title : nil }
            ?? centerTitle ?? mode.rawValue.capitalized
        let centerLayout = WheelSegmentLayout.fitted(
            L10n.text(title),
            font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
            color: solid ? .white : .labelColor,
            inside: disc,
            centers: [center],
            maximumWidth: inner * 2 - 16 * scale,
            scale: scale
        )
        WheelSegmentLayout.draw(centerLayout)
    }

    /// Dense wheels whose labels cannot all fit show icons only; the centre disc names the hovered option.
    private func layoutLabels() {
        let scale = geometry.scale
        let fitted = items.enumerated().map { i, item -> WheelSegmentLayout.Content in
            let source = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.title) }
            let baseFont = NSFont.systemFont(ofSize: (source == nil ? 13 : 9.5) * scale, weight: .semibold)
            let font = baseFont.fontDescriptor.withDesign(.rounded).flatMap {
                NSFont(descriptor: $0, size: baseFont.pointSize)
            } ?? baseFont
            return WheelSegmentLayout.fitted(
                L10n.text(item.title),
                font: font,
                color: .labelColor,
                inside: petal(i),
                centers: geometry.labelCenters(i),
                maximumWidth: 84 * scale,
                iconSize: source == nil ? nil : 20 * scale,
                scale: scale
            )
        }
        let clipped = fitted.indices.contains {
            !WheelSegmentLayout.fits(fitted[$0], inside: petal($0), padding: 3.5 * scale)
        }
        let iconOnly = clipped && fitted.allSatisfy { $0.iconRect != nil }
        labelLayouts = [:]
        for (i, layout) in fitted.enumerated() {
            guard iconOnly else {
                labelLayouts[i] = layout
                continue
            }
            let candidates = geometry.labelCenters(i).map { center -> WheelSegmentLayout.Content in
                let icon = NSRect(x: center.x - 10 * scale, y: center.y - 10 * scale, width: 20 * scale, height: 20 * scale)
                return WheelSegmentLayout.Content(
                    lines: [], textRect: icon, iconRect: icon, color: layout.color, fontSize: layout.fontSize)
            }
            labelLayouts[i] = candidates.first {
                WheelSegmentLayout.fits($0, inside: petal(i), padding: 3.5 * scale)
            } ?? candidates[0]
        }
    }

    public func labelAuditIssues(_ index: Int, title: String) -> [String] {
        guard let layout = labelLayouts[index] else { return ["Wheel label did not render: " + title] }
        var issues: [String] = []
        if !WheelSegmentLayout.fits(layout, inside: petal(index), padding: 3.5 * geometry.scale) {
            issues.append("Wheel label is clipped: " + title)
        }
        for line in layout.lines where abs(line.ink.midX - layout.textRect.midX) > 0.5 * geometry.scale {
            issues.append("Wheel line is not centered: " + line.text)
        }
        return issues
    }

    public func updateSelection(_ point: NSPoint) {
        selected = items.indices.first { petal($0).contains(point) }
    }

    public func updateAccessibility() {
        setAccessibilityLabel(
            inputs.first?.isFileURL == false ? "Filevero web media palette" : "Filevero \(mode.rawValue) palette"
        )
        let children = items.enumerated().map { index, item -> WheelAccessibilityItem in
            let child = WheelAccessibilityItem()
            child.setAccessibilityRole(.button)
            child.setAccessibilityEnabled(true)
            child.setAccessibilityLabel(L10n.text(item.operation?.title ?? item.title))
            child.setAccessibilityParent(self)
            if let w = window {
                child.setAccessibilityFrame(w.convertToScreen(convert(petal(index).bounds, to: nil)))
            }
            child.activate = { [weak self] in
                guard let self else { return false }
                self.onSelect?(item)
                return true
            }
            return child
        }
        setAccessibilityChildren(children)
    }

    override public func mouseMoved(with event: NSEvent) {
        updateSelection(convert(event.locationInWindow, from: nil))
    }

    override public func mouseExited(with event: NSEvent) {
        selected = nil
    }

    override public func mouseDown(with event: NSEvent) {
        updateSelection(convert(event.locationInWindow, from: nil))
        if let sel = selected { onSelect?(items[sel]) } else { onCancel?() }
    }

    override public func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 48:
            onCancel?()
        case 123, 126:
            if !items.isEmpty { selected = ((selected ?? 0) - 1 + items.count) % items.count }
        case 124, 125:
            if !items.isEmpty { selected = ((selected ?? -1) + 1) % items.count }
        case 115:
            selected = items.isEmpty ? nil : 0
        case 119:
            selected = items.isEmpty ? nil : items.count - 1
        case 36, 49:
            if let sel = selected { onSelect?(items[sel]) }
        default:
            break
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        onCancel?()
    }

    private func incoming(_ sender: NSDraggingInfo) -> Bool {
        let urls = WebDownloadDropPayload.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        if urls != inputs { onDragInputs?(urls) }
        updateSelection(convert(sender.draggingLocation, from: nil))
        return true
    }

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        incoming(sender) ? .copy : []
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        incoming(sender) ? .copy : []
    }

    override public func draggingExited(_ sender: NSDraggingInfo?) {
        selected = nil
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        selected != nil
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard incoming(sender), let sel = selected, items.indices.contains(sel) else {
            onCancel?()
            return false
        }
        onSelect?(items[sel])
        return true
    }

    override public func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onCancel?()
    }
}

public final class WheelAccessibilityItem: NSAccessibilityElement {
    public var activate: (() -> Bool)?
    override public func accessibilityPerformPress() -> Bool {
        activate?() ?? false
    }
}

@MainActor
public final class DragMonitor {
    private var poller: LeftMouseHoldPoller?
    private var shown = false
    private var lastMode: WheelMode?
    private var downOrigin = NSPoint.zero
    private var session = DragPasteboardSession()
    private var traceState = ""
    public let onActivate: ([URL], WheelMode, NSPoint) -> Void
    public let onEnd: () -> Void

    public init(onEnd: @escaping () -> Void, onActivate: @escaping ([URL], WheelMode, NSPoint) -> Void) {
        self.onEnd = onEnd
        self.onActivate = onActivate
        let poller = LeftMouseHoldPoller(
            onIdlePress: { [weak self] in self?.observeIdlePress() },
            tick: { [weak self] in self?.tick() })
        self.poller = poller
        poller.start()
    }

    private func observeIdlePress() {
        downOrigin = NSEvent.mouseLocation
        session.observeIdle(changeCount: NSPasteboard(name: .drag).changeCount)
    }

    public static func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        switch ModifierPreferences.wheel(for: flags) {
        case .conversions: return .convert
        case .tools: return .tools
        case .actions: return .actions
        case nil: return nil
        }
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0 || CGEventSource.buttonState(.combinedSessionState, button: .left)
        let globalFlags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        let flags = NSEvent.modifierFlags.union(globalFlags).intersection([.shift, .command, .control, .option])
        let board = NSPasteboard(name: .drag)
        let fresh = session.containsFreshDrag(
            isDown: down,
            changeCount: board.changeCount,
            now: ProcessInfo.processInfo.systemUptime
        )

        guard down, UserDefaults.standard.bool(forKey: "enabled") else {
            if shown { onEnd() }
            shown = false
            lastMode = nil
            downOrigin = NSEvent.mouseLocation
            return
        }

        let point = NSEvent.mouseLocation
        guard hypot(point.x - downOrigin.x, point.y - downOrigin.y) > 4, fresh else { return }
        guard let mode = Self.mode(for: flags), !shown || mode != lastMode else { return }

        let urls = WebDownloadDropPayload.urls(from: board)
        guard !urls.isEmpty else { return }

        if urls.first?.isFileURL != false || mode == .tools {
            shown = true
            lastMode = mode
            onActivate(urls, mode, NSEvent.mouseLocation)
        }
    }
}

