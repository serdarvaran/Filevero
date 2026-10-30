import CoreGraphics

// MARK: - SpatialCropGeometry: Image-Space Frame & Anchor Calculations

public enum SpatialCropGeometry {
    public enum Handle: Int, CaseIterable, Sendable {
        case nw, n, ne, e, se, s, sw, w

        public var x: CGFloat { [0, 0.5, 1, 1, 1, 0.5, 0, 0][rawValue] }
        public var y: CGFloat { [0, 0, 0, 0.5, 1, 1, 1, 0.5][rawValue] }
    }

    public static func selection(
        from anchor: CGPoint,
        to point: CGPoint,
        bounds: CGSize,
        aspectRatio: CGFloat?
    ) -> CGRect {
        let start = CGPoint(x: min(bounds.width, max(0, anchor.x)), y: min(bounds.height, max(0, anchor.y)))
        let dx = point.x - start.x
        let dy = point.y - start.y
        let maxWidth = dx < 0 ? start.x : bounds.width - start.x
        let maxHeight = dy < 0 ? start.y : bounds.height - start.y
        var width = min(abs(dx), maxWidth)
        var height = min(abs(dy), maxHeight)
        if let ratio = validRatio(aspectRatio) {
            width = max(abs(dx), abs(dy) * ratio)
            width = min(width, maxWidth, maxHeight * ratio)
            height = width / ratio
        }
        return CGRect(
            x: dx < 0 ? start.x - width : start.x,
            y: dy < 0 ? start.y - height : start.y,
            width: width,
            height: height)
    }

    public static func resize(
        _ rect: CGRect,
        handle: Handle,
        to point: CGPoint,
        bounds: CGSize,
        aspectRatio: CGFloat?
    ) -> CGRect {
        guard let ratio = validRatio(aspectRatio) else {
            var left = rect.minX
            var right = rect.maxX
            var top = rect.minY
            var bottom = rect.maxY
            if handle.x == 0 { left = max(0, min(right - 1, point.x)) }
            if handle.x == 1 { right = min(bounds.width, max(left + 1, point.x)) }
            if handle.y == 0 { top = max(0, min(bottom - 1, point.y)) }
            if handle.y == 1 { bottom = min(bounds.height, max(top + 1, point.y)) }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        if handle.x != 0.5, handle.y != 0.5 {
            let anchor = CGPoint(
                x: handle.x == 0 ? rect.maxX : rect.minX,
                y: handle.y == 0 ? rect.maxY : rect.minY)
            let target = CGPoint(
                x: handle.x == 0 ? min(anchor.x - 1, point.x) : max(anchor.x + 1, point.x),
                y: handle.y == 0 ? min(anchor.y - 1, point.y) : max(anchor.y + 1, point.y))
            return selection(from: anchor, to: target, bounds: bounds, aspectRatio: ratio)
        }
        // Side handles retain the opposing boundary and maintain symmetric expansion along the perpendicular axis
        if handle.x != 0.5 {
            let anchor = handle.x == 0 ? rect.maxX : rect.minX
            let available = handle.x == 0 ? anchor : bounds.width - anchor
            let maxHeight = 2 * min(rect.midY, bounds.height - rect.midY)
            let width = min(max(1, handle.x == 0 ? anchor - point.x : point.x - anchor), available, maxHeight * ratio)
            return CGRect(
                x: handle.x == 0 ? anchor - width : anchor,
                y: rect.midY - width / ratio / 2,
                width: width,
                height: width / ratio)
        }
        let anchor = handle.y == 0 ? rect.maxY : rect.minY
        let available = handle.y == 0 ? anchor : bounds.height - anchor
        let maxWidth = 2 * min(rect.midX, bounds.width - rect.midX)
        let height = min(max(1, handle.y == 0 ? anchor - point.y : point.y - anchor), available, maxWidth / ratio)
        return CGRect(
            x: rect.midX - height * ratio / 2,
            y: handle.y == 0 ? anchor - height : anchor,
            width: height * ratio,
            height: height)
    }

    public static func move(_ rect: CGRect, from start: CGPoint, to point: CGPoint, bounds: CGSize) -> CGRect {
        CGRect(
            x: max(0, min(bounds.width - rect.width, rect.minX + point.x - start.x)),
            y: max(0, min(bounds.height - rect.height, rect.minY + point.y - start.y)),
            width: rect.width,
            height: rect.height)
    }

    private static func validRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }
}

// MARK: - Compatibility Bridge
public typealias CropSelectionGeometry = SpatialCropGeometry

