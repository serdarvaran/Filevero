import AppKit
import QuickLookThumbnailing
import QuickLookUI

@MainActor
public final class ShelfFile {
    public let id = UUID()
    public let url: URL
    private var isScoped: Bool

    public init(url: URL) {
        self.url = url
        self.isScoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isScoped { url.stopAccessingSecurityScopedResource() }
    }

    public func releaseScope() {
        if isScoped {
            url.stopAccessingSecurityScopedResource()
            isScoped = false
        }
    }
}

public final class ShelfPreviewItem: NSObject, QLPreviewItem {
    public let url: URL
    public init(_ url: URL) {
        self.url = url
    }
    public var previewItemURL: URL? { url }
    public var previewItemTitle: String? { url.lastPathComponent }
}

public final class ShelfPanel: NSPanel {
    public var allowsTucking = false

    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTucking ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    public var onKey: ((NSEvent) -> Bool)?

    override public func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

@MainActor
public final class ShelfBackdrop: NSVisualEffectView {
    private let tintGradient = CAGradientLayer()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(tintGradient)
        refreshTint()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    override public func layout() {
        super.layout()
        tintGradient.frame = bounds
    }

    private func refreshTint() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tintGradient.colors = isDark
            ? [
                NSColor(srgbRed: 0.23, green: 0.25, blue: 0.18, alpha: 0.75).cgColor,
                NSColor(srgbRed: 0.10, green: 0.16, blue: 0.12, alpha: 0.8).cgColor,
            ]
            : [
                NSColor(srgbRed: 0.98, green: 0.89, blue: 0.71, alpha: 0.72).cgColor,
                NSColor(srgbRed: 0.85, green: 0.91, blue: 0.79, alpha: 0.72).cgColor,
            ]
        tintGradient.startPoint = CGPoint(x: 0.5, y: 1)
        tintGradient.endPoint = CGPoint(x: 0.5, y: 0)
    }
}

@MainActor
public final class ShelfMoveHeader: NSView {
    public var onMoveEnded: (() -> Void)?
    public var onMoving: ((Bool) -> Void)?

    override public func mouseDown(with event: NSEvent) {
        onMoving?(true)
        window?.performDrag(with: event)
        onMoving?(false)
        onMoveEnded?()
    }
}

@MainActor
public final class ShelfDropSurface: NSView {
    public var onHover: ((Bool) -> Void)?
    public var onFilesDropped: (([URL]) -> Void)?
    private var trackingArea: NSTrackingArea?

    override public func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override public func mouseEntered(with event: NSEvent) { onHover?(true) }
    override public func mouseExited(with event: NSEvent) { onHover?(false) }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    public static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.fileURLs(sender.draggingPasteboard).isEmpty
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}

@MainActor
public final class ShelfColumnLayout: NSCollectionViewLayout {
    public var itemHeight: CGFloat = 108
    public var minimumInteritemSpacing: CGFloat = 0
    public var minimumLineSpacing: CGFloat = 4
    public var sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
    private var attributeList: [NSCollectionViewLayoutAttributes] = []
    private var layoutContentSize = NSSize.zero

    override public func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(1, collectionView.bounds.width)
        let count = collectionView.numberOfItems(inSection: 0)

        attributeList = (0..<count).map { index in
            let attr = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            attr.frame = NSRect(
                x: sectionInset.left,
                y: sectionInset.top + CGFloat(index) * (itemHeight + minimumLineSpacing),
                width: max(1, width - sectionInset.left - sectionInset.right),
                height: itemHeight
            )
            return attr
        }

        layoutContentSize = NSSize(
            width: width,
            height: max(
                collectionView.bounds.height,
                sectionInset.top + CGFloat(count) * (itemHeight + minimumLineSpacing) + sectionInset.bottom
            )
        )
    }

    override public var collectionViewContentSize: NSSize { layoutContentSize }

    override public func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributeList.filter { $0.frame.intersects(rect) }
    }

    override public func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributeList.indices.contains(indexPath.item) ? attributeList[indexPath.item] : nil
    }

    override public func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}

@MainActor
public final class ShelfCollectionView: NSCollectionView {
    public var onDoubleClick: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var contextMenu: (() -> NSMenu?)?
    public var emptyMessage = "" { didSet { needsDisplay = true } }

    override public func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override public func mouseDown(with event: NSEvent) {
        let clickedItem = indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil
        super.mouseDown(with: event)
        if event.clickCount == 2, clickedItem { onDoubleClick?() }
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
        }
        return contextMenu?()
    }

    override public func layout() {
        super.layout()
        if let clip = superview as? NSClipView, frame.height < clip.bounds.height {
            frame.size.height = clip.bounds.height
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !emptyMessage.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (emptyMessage as NSString).draw(
                in: NSRect(x: 15, y: bounds.midY - 10, width: max(0, bounds.width - 30), height: 35),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }
}

@MainActor
public final class ShelfCollectionItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var fileURL: URL?
    private var viewMode: FloatShelfViewMode = .icons
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    override public var isSelected: Bool { didSet { updateVisualSelection() } }

    override public func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 13
        view.layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 11)
        name.maximumNumberOfLines = 2
        name.isSelectable = false
        name.lineBreakMode = .byWordWrapping
        detail.font = .systemFont(ofSize: 9)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        view.addSubview(icon)
        view.addSubview(name)
        view.addSubview(detail)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        if viewMode == .icons {
            icon.frame = NSRect(x: (view.bounds.width - 60) / 2, y: 43, width: 60, height: 60)
            name.alignment = .center
            name.frame = NSRect(x: 4, y: 3, width: max(0, view.bounds.width - 8), height: 35)
            detail.isHidden = true
        } else {
            icon.frame = NSRect(x: 7, y: 8, width: 32, height: 32)
            name.alignment = .left
            name.frame = NSRect(x: 49, y: 24, width: max(0, view.bounds.width - 57), height: 17)
            detail.isHidden = false
            detail.frame = NSRect(x: 49, y: 7, width: max(0, view.bounds.width - 57), height: 14)
        }
    }

    public func configure(url: URL, mode: FloatShelfViewMode) {
        _ = view
        self.fileURL = url
        self.viewMode = mode
        if let request = thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        name.stringValue = url.lastPathComponent
        detail.stringValue = url.deletingLastPathComponent().path
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        view.toolTip = url.path
        view.setAccessibilityLabel(url.lastPathComponent)
        view.needsLayout = true
        updateVisualSelection()

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 96, height: 96),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self, self.fileURL == url, let representation else { return }
                self.icon.image = representation.nsImage
            }
        }
    }

    private func updateVisualSelection() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = (isSelected ? ThemeTokenPalette.primaryAccentNS.withAlphaComponent(0.18) : NSColor.clear).cgColor
        view.layer?.borderColor = (isSelected ? ThemeTokenPalette.primaryAccentNS.withAlphaComponent(0.7) : NSColor.clear).cgColor
        view.setAccessibilitySelected(isSelected)
    }
}

@MainActor
public final class ShelfCarryGrip: NSView, NSDraggingSource {
    public var urls: (() -> [URL])?
    public var onDragEnded: (() -> Void)?
    public var contextMenu: (() -> NSMenu?)?
    override public func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    public var onClick: (() -> Void)?
    public var onInteraction: ((Bool) -> Void)?
    public var onMoveEnded: (() -> Void)?
    public var fileURLs: [URL] = [] { didSet { if oldValue != fileURLs { refreshThumbnails() } } }

    private var thumbnailMap: [URL: NSImage] = [:]
    private var activeRequests: [QLThumbnailGenerator.Request] = []
    private var dragStartOrigin = NSPoint.zero
    private var isSessionActive = false
    private var hasMoved = false

    override public var acceptsFirstResponder: Bool { true }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.text("Expand Float"))
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func refreshThumbnails() {
        for request in activeRequests { QLThumbnailGenerator.shared.cancel(request) }
        activeRequests = []
        thumbnailMap = [:]

        for url in fileURLs.suffix(3) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: NSSize(width: 96, height: 96),
                scale: window?.backingScaleFactor ?? 2,
                representationTypes: .all
            )
            activeRequests.append(request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self, self.fileURLs.suffix(3).contains(url), let result else { return }
                    self.thumbnailMap[url] = result.nsImage
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        let visible = Array(fileURLs.suffix(3))
        if visible.isEmpty {
            NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.draw(
                in: NSRect(x: 24, y: 20, width: 52, height: 52)
            )
        }

        for (index, url) in visible.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let offset = CGFloat(visible.count - index - 1)
            let transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY - 3)
            var rotated = transform
            rotated.rotate(byDegrees: offset * -7)
            rotated.translate(x: -36 + offset * -2, y: -36 - offset * 2)
            (rotated as NSAffineTransform).concat()

            let rect = NSRect(x: 0, y: 0, width: 72, height: 72)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()

            let icon = thumbnailMap[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            icon.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        let clip = NSBezierPath()
        clip.move(to: NSPoint(x: 76, y: 29))
        clip.line(to: NSPoint(x: 57, y: 72))
        clip.curve(
            to: NSPoint(x: 78, y: 81),
            controlPoint1: NSPoint(x: 47, y: 94),
            controlPoint2: NSPoint(x: 70, y: 101)
        )
        clip.line(to: NSPoint(x: 94, y: 43))
        clip.curve(
            to: NSPoint(x: 81, y: 37),
            controlPoint1: NSPoint(x: 102, y: 26),
            controlPoint2: NSPoint(x: 87, y: 22)
        )
        clip.line(to: NSPoint(x: 66, y: 72))
        clip.lineCapStyle = .round

        NSColor.black.withAlphaComponent(0.24).setStroke()
        clip.lineWidth = 4.5
        clip.stroke()

        NSColor(srgbRed: 0.76, green: 0.79, blue: 0.77, alpha: 1).setStroke()
        clip.lineWidth = 2.6
        clip.stroke()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        clip.lineWidth = 0.7
        clip.stroke()
    }

    override public func mouseDown(with event: NSEvent) {
        dragStartOrigin = convert(event.locationInWindow, from: nil)
        hasMoved = false
        onInteraction?(true)
    }

    override public func mouseUp(with event: NSEvent) {
        onInteraction?(false)
        if !hasMoved && !isSessionActive { onClick?() }
    }

    override public func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let values = urls?() ?? []
        guard !isSessionActive, hypot(point.x - dragStartOrigin.x, point.y - dragStartOrigin.y) > 3 else { return }
        hasMoved = true

        if dragStartOrigin.x > 62 && dragStartOrigin.y > 40 {
            window?.performDrag(with: event)
            onInteraction?(false)
            onMoveEnded?()
            return
        }

        guard !values.isEmpty else { return }
        let items = values.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = (thumbnailMap[url] ?? NSWorkspace.shared.icon(forFile: url.path)).copy() as! NSImage
            image.size = NSSize(width: 42, height: 42)
            item.setDraggingFrame(
                NSRect(x: point.x + CGFloat(index % 5) * 3, y: point.y + CGFloat(index % 5) * 3, width: 42, height: 42),
                contents: image
            )
            return item
        }
        isSessionActive = true
        beginDraggingSession(with: items, event: event, source: self)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link]
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isSessionActive = false
        onInteraction?(false)
        onDragEnded?()
    }
}

