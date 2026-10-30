import Foundation

/// Constructs geometric bounding boxes and coordinate anchor points for vector annotation drafts from user mouse strokes.
public enum AnnotationPathBuilder {
    
    /// Generates a standardized annotation model from user gesture coordinates.
    public static func draft(style: ImageAnnotation, points: [ImagePoint]) -> ImageAnnotation? {
        guard let firstPoint = points.first,
              let lastPoint = points.last,
              points.count >= 2,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }
        
        var draftedAnnotation = style
        let isFreehandMode = style.kind == .freehand || style.kind == .highlight
        let boundsPoints = isFreehandMode ? points : [firstPoint, lastPoint]
        
        let minX = boundsPoints.map(\.x).min()!
        let maxX = boundsPoints.map(\.x).max()!
        let minY = boundsPoints.map(\.y).min()!
        let maxY = boundsPoints.map(\.y).max()!
        
        let strokeWidth = maxX - minX
        let strokeHeight = maxY - minY
        let isLinearKind = isFreehandMode || style.kind == .line || style.kind == .arrow
        
        guard isLinearKind ? max(strokeWidth, strokeHeight) > 1.0 : (strokeWidth >= 1.0 && strokeHeight >= 1.0) else {
            return nil
        }
        
        draftedAnnotation.rect = EditRect(x: minX, y: minY, width: strokeWidth, height: strokeHeight)
        
        if isFreehandMode {
            draftedAnnotation.points = points
        } else if style.kind == .line || style.kind == .arrow {
            draftedAnnotation.points = [firstPoint, lastPoint]
        } else {
            draftedAnnotation.points = []
        }
        
        return draftedAnnotation
    }
}

public typealias AnnotationDrawing = AnnotationPathBuilder

