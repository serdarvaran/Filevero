import FileveroCore
import SwiftUI

// MARK: - AnnotationCanvasOverlay: Dynamic In-Flight Stroke Renderer

public struct AnnotationCanvasOverlay: View {
    public let draft: ImageAnnotation
    public let source: CGImage
    public let imageSize: CGSize
    public let origin: CGPoint
    public let ratio: CGFloat

    public init(
        draft: ImageAnnotation,
        source: CGImage,
        imageSize: CGSize,
        origin: CGPoint,
        ratio: CGFloat
    ) {
        self.draft = draft
        self.source = source
        self.imageSize = imageSize
        self.origin = origin
        self.ratio = ratio
    }

    public var body: some View {
        Canvas { context, _ in
            context.withCGContext { cgContext in
                cgContext.translateBy(x: origin.x, y: origin.y + imageSize.height * ratio)
                cgContext.scaleBy(x: ratio, y: -ratio)
                try? ImageEngine.drawAnnotations([draft], in: cgContext, source: source)
            }
        }
        .blendMode(draft.kind == .highlight ? .multiply : .normal)
        .allowsHitTesting(false)
    }
}

// MARK: - Compatibility Bridge
public typealias AnnotationDraftOverlay = AnnotationCanvasOverlay

