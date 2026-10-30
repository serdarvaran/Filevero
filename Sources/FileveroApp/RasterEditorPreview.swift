import AppKit
import FileveroCore
import SwiftUI

// MARK: - RasterEditorPreview: Interactive Visual Workspace Preview Canvas

public struct RasterEditorPreview: View {
    public let image: NSImage?
    public let imageSize: CGSize
    public let crop: EditRect?
    public let redactions: [EditRect]
    public let annotations: [ImageAnnotation]
    public var redactionColor: Color = .black
    public var activeRedactions: Set<Int>? = nil
    public var zoom: CGFloat = 1
    public var onStroke: ((EditRect, [ImagePoint]) -> Void)? = nil
    public var onMoveAnnotation: ((Int, EditRect, [ImagePoint]) -> Void)? = nil
    public var onMoveRedaction: ((Int, EditRect) -> Void)? = nil
    public var onMoveCrop: ((EditRect) -> Void)? = nil
    public var cropEnabled = false
    public var cropAspectRatio: CGFloat? = nil
    public var onCropInteraction: ((Bool) -> Void)? = nil
    public var annotationStyle: ImageAnnotation? = nil
    public var annotationSource: CGImage? = nil
    public var selectAnnotations = false
    public let onRect: (EditRect) -> Void

    @State private var target: DragTarget?
    @State private var startingRect: EditRect?
    @State private var startingPoints: [ImagePoint] = []
    @State private var stroke: [ImagePoint] = []
    @State private var dragRect: EditRect?
    @State private var selectedAnnotation: Int?

    public typealias Handle = SpatialCropGeometry.Handle

    public enum DragTarget {
        case crop(Handle?)
        case annotation(Int, Handle?)
        case redaction(Int, Handle?)
        case new, ignored
    }

    public init(
        image: NSImage?,
        imageSize: CGSize,
        crop: EditRect?,
        redactions: [EditRect],
        annotations: [ImageAnnotation],
        redactionColor: Color = .black,
        activeRedactions: Set<Int>? = nil,
        zoom: CGFloat = 1,
        onStroke: ((EditRect, [ImagePoint]) -> Void)? = nil,
        onMoveAnnotation: ((Int, EditRect, [ImagePoint]) -> Void)? = nil,
        onMoveRedaction: ((Int, EditRect) -> Void)? = nil,
        onMoveCrop: ((EditRect) -> Void)? = nil,
        cropEnabled: Bool = false,
        cropAspectRatio: CGFloat? = nil,
        onCropInteraction: ((Bool) -> Void)? = nil,
        annotationStyle: ImageAnnotation? = nil,
        annotationSource: CGImage? = nil,
        selectAnnotations: Bool = false,
        onRect: @escaping (EditRect) -> Void
    ) {
        self.image = image
        self.imageSize = imageSize
        self.crop = crop
        self.redactions = redactions
        self.annotations = annotations
        self.redactionColor = redactionColor
        self.activeRedactions = activeRedactions
        self.zoom = zoom
        self.onStroke = onStroke
        self.onMoveAnnotation = onMoveAnnotation
        self.onMoveRedaction = onMoveRedaction
        self.onMoveCrop = onMoveCrop
        self.cropEnabled = cropEnabled
        self.cropAspectRatio = cropAspectRatio
        self.onCropInteraction = onCropInteraction
        self.annotationStyle = annotationStyle
        self.annotationSource = annotationSource
        self.selectAnnotations = selectAnnotations
        self.onRect = onRect
    }

    public var body: some View {
        GeometryReader { geo in
            let ratio = min(geo.size.width / max(1, imageSize.width), geo.size.height / max(1, imageSize.height)) * zoom
            let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                if let selection = cropEnabled ? (dragRect ?? crop) : crop {
                    if cropEnabled {
                        Path { path in
                            path.addRect(CGRect(origin: origin, size: size))
                            path.addRect(
                                CGRect(
                                    x: origin.x + selection.x * ratio,
                                    y: origin.y + selection.y * ratio,
                                    width: selection.width * ratio,
                                    height: selection.height * ratio))
                        }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    }
                    rectangle(
                        selection,
                        ratio: ratio,
                        origin: origin,
                        color: FileveroPalette.accent,
                        fill: false,
                        handles: true)
                }
                ForEach(Array(redactions.enumerated()), id: \.offset) { i, r in
                    let active = activeRedactions?.contains(i) ?? true
                    rectangle(
                        r,
                        ratio: ratio,
                        origin: origin,
                        color: active ? redactionColor : FileveroPalette.accent,
                        fill: active,
                        handles: true)
                }
                if selectAnnotations, let index = selectedAnnotation, annotations.indices.contains(index) {
                    rectangle(
                        annotations[index].rect,
                        ratio: ratio,
                        origin: origin,
                        color: FileveroPalette.accent,
                        fill: false,
                        handles: true)
                }
                if let dragRect, !cropEnabled, annotationStyle == nil {
                    rectangle(
                        dragRect,
                        ratio: ratio,
                        origin: origin,
                        color: FileveroPalette.accent,
                        fill: false,
                        handles: false)
                }
                if case .new = target, let style = annotationStyle, let source = annotationSource,
                    let draft = AnnotationDrawing.draft(style: style, points: stroke)
                {
                    if draft.kind == .image {
                        rectangle(
                            draft.rect,
                            ratio: ratio,
                            origin: origin,
                            color: FileveroPalette.accent,
                            fill: false,
                            handles: false)
                    } else {
                        AnnotationCanvasOverlay(
                            draft: draft,
                            source: source,
                            imageSize: imageSize,
                            origin: origin,
                            ratio: ratio)
                    }
                }
                Color.clear.contentShape(Rectangle()).gesture(
                    DragGesture(minimumDistance: 2).onChanged { value in
                        updateDrag(value, origin: origin, ratio: ratio)
                    }.onEnded { value in
                        updateDrag(value, origin: origin, ratio: ratio)
                        if case .new = target, let rect = dragRect {
                            if annotationStyle != nil, let onStroke {
                                onStroke(rect, stroke)
                            } else if cropEnabled
                                ? (rect.width >= 1 && rect.height >= 1) : (rect.width > 1 || rect.height > 1)
                            {
                                onRect(rect)
                            }
                        }
                        target = nil
                        startingRect = nil
                        stroke = []
                        dragRect = nil
                        if cropEnabled { onCropInteraction?(false) }
                    }
                )
                .accessibilityLabel(
                    cropEnabled
                        ? "Crop selection canvas"
                        : annotationStyle != nil ? "Annotation canvas" : "Image editing canvas"
                )
                .accessibilityValue(
                    cropEnabled
                        ? crop.map {
                            "X \(Int($0.x)), Y \(Int($0.y)), width \(Int($0.width)), height \(Int($0.height))"
                        } ?? "No crop selected" : annotationCanvasValue
                )
                .help(
                    cropEnabled
                        ? "Drag to select. Drag inside to move. Hold Shift to lock aspect ratio. Return saves a cropped copy."
                        : "")
            }
            .clipped()
        }
        .onChange(of: selectAnnotations) { _ in
            selectedAnnotation = nil
            cancelDrag()
        }
        .onChange(of: annotationStyle?.kind) { _ in
            selectedAnnotation = nil
            cancelDrag()
        }
        .onChange(of: annotations.count) { _ in selectedAnnotation = nil }
    }

    private var annotationCanvasValue: String {
        guard let annotationStyle else { return "" }
        let mode = selectAnnotations ? "Select / Move" : annotationStyle.kind.rawValue.capitalized
        return "\(mode), \(annotations.count) annotations" + (selectedAnnotation.map { ", selected \($0 + 1)" } ?? "")
    }

    private func cancelDrag() {
        target = nil
        startingRect = nil
        startingPoints = []
        stroke = []
        dragRect = nil
    }

    private func updateDrag(_ value: DragGesture.Value, origin: CGPoint, ratio: CGFloat) {
        let start = pixel(value.startLocation, origin: origin, ratio: ratio)
        let point =
            cropEnabled
            ? CGPoint(x: (value.location.x - origin.x) / ratio, y: (value.location.y - origin.y) / ratio)
            : pixel(value.location, origin: origin, ratio: ratio)
        if target == nil {
            if cropEnabled || annotationStyle != nil,
                !CGRect(origin: origin, size: CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio))
                    .contains(value.startLocation)
            {
                target = .ignored
                return
            }
            chooseTarget(start, tolerance: 10 / max(0.1, ratio))
            stroke = [ImagePoint(x: start.x, y: start.y)]
            if cropEnabled { onCropInteraction?(true) }
        }
        let locked = NSEvent.modifierFlags.contains(.shift)
        switch target {
        case .new:
            if cropEnabled {
                let rect = SpatialCropGeometry.selection(
                    from: start, to: point, bounds: imageSize, aspectRatio: cropAspectRatio ?? (locked ? 1 : nil))
                dragRect = EditRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            } else {
                stroke.append(ImagePoint(x: point.x, y: point.y))
                dragRect = EditRect(
                    x: min(start.x, point.x),
                    y: min(start.y, point.y),
                    width: abs(point.x - start.x),
                    height: abs(point.y - start.y))
            }
        case .crop(let resize):
            if let r = startingRect {
                let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                let updated: CGRect
                if let resize {
                    updated = SpatialCropGeometry.resize(
                        rect,
                        handle: resize,
                        to: point,
                        bounds: imageSize,
                        aspectRatio: cropAspectRatio ?? (locked ? rect.width / max(1, rect.height) : nil))
                } else {
                    updated = SpatialCropGeometry.move(rect, from: start, to: point, bounds: imageSize)
                }
                onMoveCrop?(EditRect(x: updated.minX, y: updated.minY, width: updated.width, height: updated.height))
            }
        case .redaction(let i, let resize):
            if let r = startingRect {
                onMoveRedaction?(i, changed(r, start: start, current: point, resize: resize))
            }
        case .annotation(let i, let resize):
            if let r = startingRect {
                let updated = changed(r, start: start, current: point, resize: resize)
                let points = startingPoints.map { p in
                    ImagePoint(
                        x: updated.x + (p.x - r.x) * (updated.width / max(1, r.width)),
                        y: updated.y + (p.y - r.y) * (updated.height / max(1, r.height)))
                }
                onMoveAnnotation?(i, updated, points)
            }
        case .ignored, nil:
            break
        }
    }

    private func pixel(_ p: CGPoint, origin: CGPoint, ratio: CGFloat) -> CGPoint {
        CGPoint(
            x: max(0, min(imageSize.width, (p.x - origin.x) / ratio)),
            y: max(0, min(imageSize.height, (p.y - origin.y) / ratio)))
    }

    private func chooseTarget(_ point: CGPoint, tolerance: CGFloat) {
        if annotationStyle != nil, !selectAnnotations {
            target = .new
            selectedAnnotation = nil
            return
        }
        func hit(_ r: EditRect) -> (Bool, Handle?) {
            let b = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let handle = Handle.allCases.min {
                hypot(point.x - (b.minX + b.width * $0.x), point.y - (b.minY + b.height * $0.y))
                    < hypot(point.x - (b.minX + b.width * $1.x), point.y - (b.minY + b.height * $1.y))
            }
            let close = handle.flatMap { h in
                hypot(point.x - (b.minX + b.width * h.x), point.y - (b.minY + b.height * h.y)) <= tolerance ? h : nil
            }
            return (b.insetBy(dx: -tolerance, dy: -tolerance).contains(point), close)
        }
        for (i, a) in annotations.enumerated().reversed() where onMoveAnnotation != nil {
            let h = hit(a.rect)
            if h.0 {
                target = .annotation(i, h.1)
                selectedAnnotation = i
                startingRect = a.rect
                startingPoints = a.points
                return
            }
        }
        if annotationStyle != nil, selectAnnotations {
            selectedAnnotation = nil
            target = .ignored
            return
        }
        for (i, r) in redactions.enumerated().reversed() where onMoveRedaction != nil {
            let h = hit(r)
            if h.0 {
                target = .redaction(i, h.1)
                startingRect = r
                return
            }
        }
        if let crop, onMoveCrop != nil {
            let h = hit(crop)
            if h.0 {
                target = .crop(h.1)
                startingRect = crop
                return
            }
        }
        target = .new
    }

    private func changed(_ rect: EditRect, start: CGPoint, current: CGPoint, resize: Handle?) -> EditRect {
        if let resize {
            var left = rect.x
            var right = rect.x + rect.width
            var top = rect.y
            var bottom = rect.y + rect.height
            if resize.x == 0 { left = max(0, min(right - 1, current.x)) }
            if resize.x == 1 { right = min(imageSize.width, max(left + 1, current.x)) }
            if resize.y == 0 { top = max(0, min(bottom - 1, current.y)) }
            if resize.y == 1 { bottom = min(imageSize.height, max(top + 1, current.y)) }
            return EditRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        return EditRect(
            x: max(0, min(imageSize.width - rect.width, rect.x + current.x - start.x)),
            y: max(0, min(imageSize.height - rect.height, rect.y + current.y - start.y)),
            width: rect.width,
            height: rect.height)
    }

    private func rectangle(_ r: EditRect, ratio: CGFloat, origin: CGPoint, color: Color, fill: Bool, handles: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(fill ? color : .clear)
                .overlay(Rectangle().stroke(color, lineWidth: 1.5))
            if handles {
                ForEach(Handle.allCases, id: \.rawValue) { h in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FileveroPalette.accent)
                        .frame(width: 8, height: 8)
                        .offset(x: r.width * ratio * h.x - 4, y: r.height * ratio * h.y - 4)
                }
            }
        }
        .frame(width: max(1, r.width * ratio), height: max(1, r.height * ratio))
        .offset(x: origin.x + r.x * ratio, y: origin.y + r.y * ratio)
    }
}

// MARK: - Compatibility Bridge
public typealias ImageEditPreview = RasterEditorPreview

