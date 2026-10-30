import AppKit
import FileveroCore

/// Dedicated menu bar status item drag-and-drop receptor view.
/// Allows users to drag any file from Finder directly onto the menu bar icon to invoke the spatial wheel.
public final class StatusBarDropZoneView: NSView {
    public var onDrop: (([URL], NSPoint) -> Void)?
    private var isDragOver = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, types.contains(.fileURL) else {
            return []
        }
        isDragOver = true
        needsDisplay = true
        return .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragOver = false
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDragOver = false
        needsDisplay = true

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        let anchorPoint: NSPoint
        if let window = self.window {
            let windowRect = convert(bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            anchorPoint = NSPoint(x: screenRect.midX, y: screenRect.minY - 10)
        } else {
            anchorPoint = NSEvent.mouseLocation
        }

        onDrop?(urls, anchorPoint)
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDragOver {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            let highlightPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            highlightPath.fill()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }
}

