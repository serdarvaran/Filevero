import AppKit
import QuickLookUI

public enum FloatShelfEdge: String, CaseIterable, Sendable {
    case top, right, bottom, left
}

public enum FloatShelfViewMode: Int, Sendable {
    case icons, list
}

@MainActor
public final class FloatingStagingShelfController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource,
    NSCollectionViewDelegate, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate,
    NSMenuItemValidation, NSMenuDelegate
{
    public var onClose: (() -> Void)?
    public private(set) var isExpanded = false
    public private(set) var viewMode: FloatShelfViewMode = .icons
    public private(set) var attachedEdge: FloatShelfEdge?
    public var urls: [URL] { items.map(\.url) }
    public var selectedURLs: [URL] { selectedIndices.map { items[$0].url } }

    private var items: [ShelfFile] = []
    private let surface = ShelfDropSurface()
    private let header = ShelfMoveHeader()
    private let collection = ShelfCollectionView()
    private let scroll = NSScrollView()
    private let flow = ShelfColumnLayout()
    private let statusLabel = NSTextField(labelWithString: "")
    private let collapseButton = NSButton()
    private let pinButton = NSButton()
    private let carryGrip = ShelfCarryGrip()
    private let glass = ShelfBackdrop()
    private var hoverTask: Task<Void, Never>?
    private var interacting = false
    private var headerHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var isAdjustingFrame = false
    private let filePreview = FilePreview()
    private var previewItems: [ShelfPreviewItem] = []
    private var sharingPicker: NSSharingServicePicker?
    private var typeBuffer = ""
    private var lastTypeTime: TimeInterval = 0
    private var isClosed = false
    private var languageObserver: NSObjectProtocol?

    private var selectedIndices: [Int] {
        collection.selectionIndexPaths.map(\.item).filter { items.indices.contains($0) }.sorted()
    }
    private var actionURLs: [URL] { selectedURLs.isEmpty ? urls : selectedURLs }

    public init(urls: [URL]) {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 112, height: 136)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.standardWindow)
        panel.title = "Float"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 112, height: 136)
        panel.delegate = self
        panel.contentView = surface

        buildContent()
        append(urls)

        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(
            NSPoint(
                x: max(visible.minX, min(visible.maxX - 112, pointer.x + 24)),
                y: max(visible.minY, min(visible.maxY - 136, pointer.y - 68))
            )
        )
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .fileveroLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateLabels() }
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(isExpanded ? collection : carryGrip)
    }

    public func append(_ urls: [URL]) {
        let previousSelection = Set(selectedIndices.map { items[$0].id })
        var present = Set(items.map { $0.url.standardizedFileURL.path })
        for url in urls where url.isFileURL {
            let canonical = url.standardizedFileURL
            if present.insert(canonical.path).inserted {
                items.append(ShelfFile(url: canonical))
            }
        }
        reload(preserving: previousSelection)
        if isExpanded { setExpanded(true, forceLayout: true) }
    }

    public func attach(to edge: FloatShelfEdge?) {
        attachedEdge = edge
        (window as? ShelfPanel)?.allowsTucking = edge == .top && !isExpanded
        if let edge, let window, let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            let visible = screen.visibleFrame
            switch edge {
            case .left: frame.origin.x = visible.minX
            case .right: frame.origin.x = visible.maxX - frame.width
            case .top: frame.origin.y = visible.maxY - frame.height
            case .bottom: frame.origin.y = visible.minY
            }
            frame.origin.x = max(visible.minX, min(visible.maxX - frame.width, frame.minX))
            frame.origin.y = max(visible.minY, min(visible.maxY - frame.height, frame.minY))
            if !isExpanded, edge == .top { frame.origin.y = visible.maxY - frame.height + 96 }
            setFrame(frame, animate: true)
        }
        updateLabels()
    }

    private func buildContent() {
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 24
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        surface.onFilesDropped = { [weak self] urls in self?.append(urls) }
        surface.onHover = { [weak self] inside in self?.scheduleHover(inside) }

        header.onMoving = { [weak self] active in
            self?.interacting = active
            self?.hoverTask?.cancel()
        }
        header.onMoveEnded = { [weak self] in
            self?.snapAfterMove()
            self?.scheduleHover(false)
        }

        let close = makeButton("xmark.circle.fill", help: L10n.text("Close Float without deleting files"), action: #selector(closeShelf))
        close.setAccessibilityIdentifier("float.close")

        pinButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.text("Float options"))
        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(showOptions)
        pinButton.toolTip = L10n.text("Float options")
        pinButton.setAccessibilityIdentifier("float.options")

        for control in [close, pinButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(control)
        }

        carryGrip.urls = { [weak self] in self?.urls ?? [] }
        carryGrip.contextMenu = { [weak self] in self?.makeContextMenu() }
        carryGrip.onClick = { [weak self] in self?.toggleExpanded() }
        carryGrip.onDragEnded = { [weak self] in
            self?.interacting = false
            self?.refreshAfterDrag()
            self?.scheduleHover(false)
        }
        carryGrip.onInteraction = { [weak self] in
            self?.interacting = $0
            self?.hoverTask?.cancel()
        }
        carryGrip.onMoveEnded = { [weak self] in self?.snapAfterMove() }
        carryGrip.setAccessibilityIdentifier("float.carry")
        carryGrip.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(carryGrip)

        collapseButton.font = .systemFont(ofSize: 11, weight: .medium)
        collapseButton.alignment = .center
        collapseButton.bezelStyle = .inline
        collapseButton.isBordered = false
        collapseButton.target = self
        collapseButton.action = #selector(toggleExpanded)
        collapseButton.setAccessibilityIdentifier("float.collapse")
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapseButton)

        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 9),
            close.topAnchor.constraint(equalTo: header.topAnchor, constant: 9),
            pinButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -9),
            pinButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 9),
            carryGrip.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            carryGrip.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            carryGrip.widthAnchor.constraint(equalToConstant: 100),
            carryGrip.heightAnchor.constraint(equalToConstant: 100),
            collapseButton.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            collapseButton.topAnchor.constraint(equalTo: carryGrip.bottomAnchor, constant: 2),
            collapseButton.widthAnchor.constraint(equalToConstant: 104),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        close.identifier = NSUserInterfaceItemIdentifier("float.closeControl")
        header.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(header)
        headerHeight = header.heightAnchor.constraint(equalToConstant: 126)

        flow.minimumInteritemSpacing = 0
        flow.minimumLineSpacing = 4
        flow.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)

        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(ShelfCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("FloatFile"))
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.onDoubleClick = { [weak self] in self?.openSelection() }
        collection.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        collection.contextMenu = { [weak self] in self?.makeContextMenu() }
        collection.frame = NSRect(x: 0, y: 0, width: 156, height: 230)
        collection.autoresizingMask = [.width]
        collection.setAccessibilityIdentifier("float.files")
        collection.setAccessibilityLabel(L10n.text("Files in Float"))

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(scroll)

        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(statusLabel)
        statusHeight = statusLabel.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            header.topAnchor.constraint(equalTo: surface.topAnchor), headerHeight,
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: surface.bottomAnchor), statusHeight,
        ])
        updatePresentation()
    }

    private func updatePresentation() {
        glass.isHidden = !isExpanded
        glass.frame = surface.bounds
        scroll.isHidden = !isExpanded
        statusLabel.isHidden = !isExpanded
        pinButton.isHidden = !isExpanded
        header.subviews.first { $0.identifier?.rawValue == "float.closeControl" }?.isHidden = !isExpanded
        headerHeight.constant = isExpanded ? 140 : 136
        statusHeight.constant = isExpanded ? 22 : 0
        collapseButton.wantsLayer = true
        collapseButton.layer?.cornerRadius = 11
        collapseButton.layer?.backgroundColor = (isExpanded ? NSColor.clear : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).cgColor
        window?.hasShadow = isExpanded
    }

    private func scheduleHover(_ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: inside ? 200_000_000 : 650_000_000)
            guard !Task.isCancelled, let self, !self.interacting, NSEvent.pressedMouseButtons == 0,
                  let window = self.window
            else { return }
            let isInside = window.frame.contains(NSEvent.mouseLocation)
            if inside && isInside {
                self.setExpanded(true)
            } else if !inside && !isInside {
                self.setExpanded(false)
            }
        }
    }

    @objc private func showOptions(_ sender: NSButton) {
        interacting = true
        hoverTask?.cancel()
        makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        interacting = false
        scheduleHover(false)
    }

    private func makeButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let result = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        result.bezelStyle = .inline
        result.isBordered = false
        result.toolTip = help
        result.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return result
    }

    private func reload(preserving ids: Set<UUID> = []) {
        flow.itemHeight = viewMode == .list ? 48 : 108
        collection.reloadData()
        collection.selectionIndexPaths = Set(
            items.enumerated().filter { ids.contains($0.element.id) }.map { IndexPath(item: $0.offset, section: 0) }
        )
        flow.invalidateLayout()
        updateLabels()
        updatePreviewIfVisible()
    }

    private func updateLabels() {
        let selected = selectedIndices.count
        let count = items.count
        collapseButton.title = (isExpanded ? "⌃  " : "⌄  ") + L10n.text(count == 1 ? "1 item" : "\(count) items")
        statusLabel.stringValue = L10n.text(selected > 0 ? "\(selected) selected" : "Space · Preview")
        collection.emptyMessage = count == 0 ? L10n.text("Drop files here") : ""
        carryGrip.fileURLs = urls
        carryGrip.needsDisplay = true
        carryGrip.setAccessibilityLabel(L10n.text(isExpanded ? "Collapse Float" : "Expand Float"))
        carryGrip.toolTip = L10n.text("Drag the stack to carry all files. Drag the paperclip to move Float.")
        collapseButton.toolTip = L10n.text(isExpanded ? "Collapse Float" : "Expand Float")
        collapseButton.setAccessibilityLabel(L10n.text(isExpanded ? "Collapse Float" : "Expand Float") + " · \(count)")
        window?.title = L10n.text(count == 1 ? "Float · 1 file" : "Float · \(count) files")
        window?.invalidateShadow()
    }

    private func setFrame(_ frame: NSRect, animate: Bool) {
        isAdjustingFrame = true
        defer { isAdjustingFrame = false }
        window?.setFrame(frame, display: true, animate: animate && FileveroMotion.enabled)
    }

    private func snapAfterMove() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let distances: [(FloatShelfEdge, CGFloat)] = [
            (.left, abs(frame.minX - visible.minX)),
            (.right, abs(frame.maxX - visible.maxX)),
            (.top, abs(frame.maxY - visible.maxY)),
            (.bottom, abs(frame.minY - visible.minY)),
        ]
        if let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= 20 {
            attach(to: nearest.0)
        } else {
            attach(to: nil)
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, let edge = attachedEdge, let window, let screen = window.screen else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let distance: CGFloat
        switch edge {
        case .left: distance = abs(frame.minX - visible.minX)
        case .right: distance = abs(frame.maxX - visible.maxX)
        case .top: distance = abs(frame.maxY - visible.maxY)
        case .bottom: distance = abs(frame.minY - visible.minY)
        }
        if distance > 35 {
            attachedEdge = nil
            updateLabels()
        }
    }

    public func windowDidResize(_ notification: Notification) {
        collection.frame.size.width = scroll.contentSize.width
        flow.invalidateLayout()
        if let edge = attachedEdge, !isAdjustingFrame { attach(to: edge) }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        hoverTask?.cancel()
        filePreview.close()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.delegate === self {
            panel.orderOut(nil)
            panel.delegate = nil
            panel.dataSource = nil
        }
        for item in items { item.releaseScope() }
        items = []
        previewItems = []
        onClose?()
    }

    @objc private func closeShelf() { close() }
    @objc private func toggleExpanded() { setExpanded(!isExpanded) }

    public func setExpanded(_ value: Bool, forceLayout: Bool = false) {
        guard isExpanded != value || forceLayout, let window else { return }
        hoverTask?.cancel()
        let old = window.frame
        isExpanded = value
        (window as? ShelfPanel)?.allowsTucking = attachedEdge == .top && !value
        updatePresentation()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? old
        let height = min(
            visible.height - 16,
            CGFloat(162 + max(1, min(items.count, 5)) * (viewMode == .icons ? 112 : 52))
        )
        let size = value ? NSSize(width: viewMode == .icons ? 156 : 284, height: height) : NSSize(width: 112, height: 136)
        var origin = NSPoint(x: old.midX - size.width / 2, y: old.maxY - size.height)
        if attachedEdge == .right { origin.x = old.maxX - size.width }
        if attachedEdge == .bottom { origin.y = old.minY }
        origin.x = max(visible.minX, min(visible.maxX - size.width, origin.x))
        origin.y = max(visible.minY, min(visible.maxY - size.height, origin.y))
        setFrame(NSRect(origin: origin, size: size), animate: true)
        if let edge = attachedEdge { attach(to: edge) }
        updateLabels()
        surface.layoutSubtreeIfNeeded()
        flow.invalidateLayout()
        window.makeFirstResponder(value ? collection : carryGrip)
    }

    @objc private func showPinMenu(_ sender: NSButton) {
        let menu = pinMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    private func pinMenu() -> NSMenu {
        let menu = NSMenu(title: "Attach to Edge")
        for edge in FloatShelfEdge.allCases {
            let item = NSMenuItem(
                title: L10n.text(edge.rawValue.capitalized),
                action: #selector(pinChoice),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = edge.rawValue
            item.state = attachedEdge == edge ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let detach = NSMenuItem(title: L10n.text("Detach"), action: #selector(pinChoice), keyEquivalent: "")
        detach.target = self
        detach.state = attachedEdge == nil ? .on : .off
        menu.addItem(detach)
        return menu
    }

    @objc private func pinChoice(_ sender: NSMenuItem) {
        attach(to: (sender.representedObject as? String).flatMap(FloatShelfEdge.init(rawValue:)))
    }

    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("FloatFile"), for: indexPath) as! ShelfCollectionItem
        item.configure(url: items[indexPath.item].url, mode: viewMode)
        return item
    }

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateLabels()
        updatePreviewIfVisible()
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateLabels()
        updatePreviewIfVisible()
    }

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !indexPaths.isEmpty
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items[indexPath.item].url as NSURL
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        refreshAfterDrag()
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        if let src = draggingInfo.draggingSource as? NSCollectionView, src === collectionView { return [] }
        guard !ShelfDropSurface.fileURLs(draggingInfo.draggingPasteboard).isEmpty else { return [] }
        proposedDropIndexPath.pointee = IndexPath(item: items.count, section: 0) as NSIndexPath
        proposedDropOperation.pointee = .before
        return .copy
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let values = ShelfDropSurface.fileURLs(draggingInfo.draggingPasteboard)
        guard !values.isEmpty else { return false }
        append(values)
        return true
    }

    private func refreshAfterDrag() {
        collection.reloadData()
        updateLabels()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                setExpanded(true)
                collection.selectAll(nil)
                return true
            case "c":
                if event.modifierFlags.contains(.option) { copyPaths() } else { copyFiles() }
                return true
            case "v":
                append(ShelfDropSurface.fileURLs(.general))
                return true
            case "o":
                openSelection()
                return true
            case "r":
                revealSelection()
                return true
            default:
                return false
            }
        }
        if event.keyCode == 49 {
            showQuickLook()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            removeSelection()
            return true
        }
        if event.keyCode == 53 {
            if !collection.selectionIndexPaths.isEmpty {
                collection.selectionIndexPaths = []
                updateLabels()
            } else {
                setExpanded(false)
            }
            return true
        }
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
              let value = event.characters, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " })
        else { return false }

        let time = ProcessInfo.processInfo.systemUptime
        let query = value.lowercased()
        if time - lastTypeTime > 1 { typeBuffer = "" }
        lastTypeTime = time
        let repeated = typeBuffer == query
        typeBuffer = repeated ? query : typeBuffer + query
        let start = repeated ? (selectedIndices.first ?? -1) + 1 : 0
        for offset in items.indices {
            let index = (start + offset) % items.count
            if items[index].url.lastPathComponent.lowercased().hasPrefix(typeBuffer) {
                collection.selectItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
                return true
            }
        }
        return !items.isEmpty
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Float")
        menu.delegate = self
        let commands: [(String, Selector)] = [
            ("Open", #selector(openSelection)),
            ("Quick Look", #selector(showQuickLook)),
            ("Show in Finder", #selector(revealSelection)),
            ("Copy", #selector(copyFiles)),
            ("Copy Path", #selector(copyPaths)),
            ("Share…", #selector(shareSelection)),
            ("Remove from Float", #selector(removeSelection)),
        ]
        for (title, action) in commands {
            let item = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, mode) in [("Icons", FloatShelfViewMode.icons), ("List", .list)] {
            let item = NSMenuItem(title: L10n.text(title), action: #selector(selectViewMode), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = viewMode == mode ? .on : .off
            menu.addItem(item)
        }
        let add = NSMenuItem(title: L10n.text("Add Files…"), action: #selector(chooseFiles), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let clear = NSMenuItem(title: L10n.text("Clear Float"), action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let pin = NSMenuItem(title: L10n.text("Attach to Edge"), action: nil, keyEquivalent: "")
        pin.submenu = pinMenu()
        menu.addItem(pin)
        return menu
    }

    @objc private func selectViewMode(_ sender: NSMenuItem) {
        setViewMode(FloatShelfViewMode(rawValue: sender.tag) ?? .icons)
    }

    public func setViewMode(_ mode: FloatShelfViewMode) {
        let selected = Set(selectedIndices.map { items[$0].id })
        viewMode = mode
        if isExpanded { setExpanded(false) }
        reload(preserving: selected)
        setExpanded(true)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        interacting = true
        hoverTask?.cancel()
    }

    public func menuDidClose(_ menu: NSMenu) {
        interacting = false
        scheduleHover(false)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseFiles) || menuItem.action == #selector(selectViewMode) { return true }
        if menuItem.action == #selector(removeSelection) { return !selectedIndices.isEmpty }
        if menuItem.action == #selector(pinChoice) { return true }
        return !items.isEmpty
    }

    @objc private func openSelection() {
        for url in actionURLs {
            if !NSWorkspace.shared.open(url) { statusLabel.stringValue = L10n.text("Could not open \(url.lastPathComponent).") }
        }
    }

    @objc private func revealSelection() {
        if !actionURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(actionURLs) }
    }

    @objc private func copyFiles() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(actionURLs.map { $0 as NSURL })
    }

    @objc private func copyPaths() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actionURLs.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func shareSelection() {
        guard !actionURLs.isEmpty else { return }
        sharingPicker = NSSharingServicePicker(items: actionURLs)
        sharingPicker?.show(relativeTo: carryGrip.bounds, of: carryGrip, preferredEdge: .minY)
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("Add to Float")
        if panel.runModal() == .OK { append(panel.urls) }
    }

    @objc private func removeSelection() {
        let selected = Set(selectedIndices)
        for index in selected { items[index].releaseScope() }
        items = items.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
        reload()
        if isExpanded { setExpanded(true, forceLayout: true) }
    }

    @objc private func clearShelf() {
        for item in items { item.releaseScope() }
        items = []
        reload()
        if isExpanded { setExpanded(true, forceLayout: true) }
    }

    @objc private func showQuickLook() { filePreview.show(actionURLs) }

    private func updatePreviewIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.delegate === self
        else { return }
        previewItems = actionURLs.map(ShelfPreviewItem.init)
        panel.reloadData()
        if previewItems.isEmpty { panel.orderOut(nil) }
    }

    override public func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !items.isEmpty }

    override public func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override public func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems.indices.contains(index) ? previewItems[index] : nil
    }

    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}

// Backward-compatibility alias
public typealias FloatShelfController = FloatingStagingShelfController

