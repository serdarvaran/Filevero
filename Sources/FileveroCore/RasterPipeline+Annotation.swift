import AppKit
import CoreGraphics
import CoreText
import Foundation
import Vision

extension RasterPipeline {
    public static func annotatedImage(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        try annotate(image, options: options)
    }

    static func annotate(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        let context = try canvas(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        
        var combinedAnnotations = options.annotations.map { legacy -> ImageAnnotation in
            var item = ImageAnnotation(kind: ImageAnnotationKind(rawValue: legacy.kind) ?? .text, rect: legacy.rect)
            item.text = legacy.text
            item.color = legacy.color
            item.fontSize = max(12.0, legacy.rect.height * 0.7)
            item.strokeWidth = max(2.0, legacy.rect.height / 15.0)
            if item.kind == .number {
                item.number = Int(legacy.text) ?? 1
            }
            return item
        }
        combinedAnnotations += options.imageAnnotations
        
        try drawAnnotations(combinedAnnotations, in: context, source: image)
        guard let result = context.makeImage() else {
            throw FileveroError.failed("Could not annotate image.")
        }
        return result
    }

    public static func drawAnnotations(
        _ annotations: [ImageAnnotation],
        in context: CGContext,
        source image: CGImage
    ) throws {
        for item in annotations {
            let rect = item.rect
            guard [
                rect.x, rect.y, rect.width, rect.height, item.strokeWidth, item.opacity, item.fontSize, item.magnification
            ].allSatisfy(\.isFinite) else {
                throw FileveroError.invalidInput("Annotation coordinates must be finite.")
            }
            
            let r = CGRect(
                x: rect.x,
                y: Double(image.height) - rect.y - rect.height,
                width: rect.width,
                height: rect.height
            ).standardized
            
            let mapPoint: (ImagePoint) -> CGPoint = { CGPoint(x: $0.x, y: Double(image.height) - $0.y) }
            
            context.saveGState()
            defer { context.restoreGState() }
            
            context.setAlpha(max(0.0, min(1.0, item.opacity)))
            context.setStrokeColor(color(item.color))
            context.setFillColor(color(item.fillColor ?? item.color))
            context.setLineWidth(max(0.5, item.strokeWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            
            switch item.kind {
            case .rectangle:
                if item.fillColor != nil { context.fill(r) }
                context.stroke(r)
                
            case .ellipse:
                if item.fillColor != nil { context.fillEllipse(in: r) }
                context.strokeEllipse(in: r)
                
            case .line, .arrow:
                let linePoints = item.points.count >= 2
                    ? item.points.map(mapPoint)
                    : [
                        mapPoint(.init(x: rect.x, y: rect.y)),
                        mapPoint(.init(x: rect.x + rect.width, y: rect.y + rect.height)),
                    ]
                guard let start = linePoints.first, let end = linePoints.last else { continue }
                context.move(to: start)
                for pt in linePoints.dropFirst() { context.addLine(to: pt) }
                context.strokePath()
                
                if item.kind == .arrow {
                    let previous = linePoints[linePoints.count - 2]
                    let angle = atan2(end.y - previous.y, end.x - previous.x)
                    let arrowSize = max(10.0, item.strokeWidth * 4.0)
                    let leftWing = CGPoint(
                        x: end.x - arrowSize * cos(angle - .pi / 6.0),
                        y: end.y - arrowSize * sin(angle - .pi / 6.0)
                    )
                    let rightWing = CGPoint(
                        x: end.x - arrowSize * cos(angle + .pi / 6.0),
                        y: end.y - arrowSize * sin(angle + .pi / 6.0)
                    )
                    context.move(to: leftWing)
                    context.addLine(to: end)
                    context.addLine(to: rightWing)
                    context.strokePath()
                }
                
            case .freehand, .highlight:
                let strokePoints = item.points.isEmpty
                    ? [
                        mapPoint(.init(x: rect.x, y: rect.y)),
                        mapPoint(.init(x: rect.x + rect.width, y: rect.y + rect.height)),
                    ]
                    : item.points.map(mapPoint)
                    
                if item.kind == .highlight {
                    context.setAlpha(max(0.0, min(1.0, item.opacity)) * 0.35)
                    context.setBlendMode(.multiply)
                    context.setLineWidth(max(12.0, item.strokeWidth))
                }
                if let first = strokePoints.first {
                    context.move(to: first)
                    for pt in strokePoints.dropFirst() { context.addLine(to: pt) }
                    context.strokePath()
                }
                
            case .text:
                drawText(
                    item.text,
                    in: r,
                    context: context,
                    color: color(item.color),
                    fontSize: item.fontSize,
                    fontFamily: item.fontFamily
                )
                
            case .number:
                context.fillEllipse(in: r)
                drawCenteredText(
                    String(item.number),
                    in: r,
                    context: context,
                    color: CGColor(gray: 1.0, alpha: 1.0),
                    fontSize: min(r.width, r.height) * 0.58
                )
                
            case .callout:
                let body = CGRect(x: r.minX, y: r.minY + r.height * 0.2, width: r.width, height: r.height * 0.8)
                context.addPath(CGPath(roundedRect: body, cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
                context.move(to: CGPoint(x: body.minX + body.width * 0.18, y: body.minY + 1))
                context.addLine(to: CGPoint(x: body.minX + body.width * 0.1, y: r.minY))
                context.addLine(to: CGPoint(x: body.minX + body.width * 0.4, y: body.minY + 1))
                context.fillPath()
                drawCenteredText(
                    item.text.isEmpty ? String(item.number) : item.text,
                    in: body.insetBy(dx: 6, dy: 2),
                    context: context,
                    color: CGColor(gray: 1.0, alpha: 1.0),
                    fontSize: item.fontSize
                )
                
            case .magnifier:
                guard item.magnification > 0 else {
                    throw FileveroError.invalidInput("Magnification must be positive.")
                }
                let sourceBounds = item.sourceRect ?? EditRect(
                    x: rect.x + rect.width * (1.0 - 1.0 / item.magnification) / 2.0,
                    y: rect.y + rect.height * (1.0 - 1.0 / item.magnification) / 2.0,
                    width: rect.width / item.magnification,
                    height: rect.height / item.magnification
                )
                let sourcePixels = CGRect(
                    x: sourceBounds.x,
                    y: sourceBounds.y,
                    width: sourceBounds.width,
                    height: sourceBounds.height
                ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                
                if let cropped = image.cropping(to: sourcePixels), !sourcePixels.isEmpty {
                    context.saveGState()
                    context.addEllipse(in: r)
                    context.clip()
                    context.interpolationQuality = .high
                    context.draw(cropped, in: r)
                    context.restoreGState()
                    context.strokeEllipse(in: r)
                }
                
            case .image:
                guard let imageURL = item.imageURL else {
                    throw FileveroError.invalidInput("Choose an image for the annotation.")
                }
                let overlay = try load(imageURL)
                drawFitted(overlay, in: r, context: context, fit: .fit)
            }
        }
    }

    static func drawText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        color: CGColor,
        fontSize: Double,
        fontFamily: String = "system"
    ) {
        let systemDesign: NSFontDescriptor.SystemDesign = fontFamily == "rounded"
            ? .rounded
            : fontFamily == "serif" ? .serif : fontFamily == "monospaced" ? .monospaced : .default
            
        let baseFont = NSFont.systemFont(ofSize: max(1.0, fontSize), weight: .semibold)
        let chosenFont = baseFont.fontDescriptor.withDesign(systemDesign).flatMap {
            NSFont(descriptor: $0, size: max(1.0, fontSize))
        } ?? baseFont
        
        let ctFont = chosenFont as CTFont
        let attributedString = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let path = CGPath(rect: rect, transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
    }

    static func drawCenteredText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        color: CGColor,
        fontSize: Double
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(1.0, fontSize), nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]
            )
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: rect.midX - width / 2.0, y: rect.midY - (ascent - descent) / 2.0)
        CTLineDraw(line, context)
    }

    static func drawFitted(_ image: CGImage, in rect: CGRect, context: CGContext, fit: ImageFit) {
        let sx = rect.width / CGFloat(image.width)
        let sy = rect.height / CGFloat(image.height)
        let scale = fit == .fill ? max(sx, sy) : min(sx, sy)
        let target = CGRect(
            x: rect.midX - CGFloat(image.width) * scale / 2.0,
            y: rect.midY - CGFloat(image.height) * scale / 2.0,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        context.restoreGState()
    }

    public static func redactedImage(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        try redact(image, options: options)
    }

    static func redact(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        var settings = options.imageRedaction ?? ImageRedactionOptions()
        if options.imageRedaction == nil {
            settings.style = options.redactionMode == "black" || options.redactionMode == "solid"
                ? .solid
                : options.redactionMode == "pixelate" ? .pixelate : .blur
        }
        
        var regions = options.redactions
        if settings.detectFaces || settings.detectText {
            regions += try recognizedRegions(
                image,
                faces: settings.detectFaces,
                text: settings.detectText,
                padding: settings.detectionPadding
            ).map(\.rect)
        }
        
        guard !regions.isEmpty else {
            throw FileveroError.invalidInput("Select an area to redact, or detect faces or text.")
        }
        guard settings.blurRadius.isFinite, settings.pixelSize.isFinite else {
            throw FileveroError.invalidInput("Redaction strength must be finite.")
        }
        
        let width = Double(image.width)
        let height = Double(image.height)
        for rect in regions {
            guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite) else {
                throw FileveroError.invalidInput(
                    "Redaction coordinates must be finite for the \(image.width) × \(image.height) pixel image."
                )
            }
            guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
                  rect.x <= width, rect.y <= height, rect.width <= width - rect.x, rect.height <= height - rect.y
            else {
                throw FileveroError.invalidInput(
                    "Every redaction area must have positive dimensions and fit completely inside the \(image.width) × \(image.height) pixel image. Adjust the areas for this image and try again."
                )
            }
        }
        
        let context = try canvas(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        
        for rect in regions {
            let pixels = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).integral
            let target = CGRect(
                x: pixels.minX,
                y: CGFloat(image.height) - pixels.maxY,
                width: pixels.width,
                height: pixels.height
            )
            
            if settings.style == .solid {
                context.setFillColor(color(settings.color).copy(alpha: 1.0)!)
                context.fill(target)
            } else if let part = image.cropping(to: pixels) {
                let original = CIImage(cgImage: part)
                let bounds = original.extent
                let filtered: CIImage
                
                if settings.style == .blur {
                    filtered = original.clampedToExtent().applyingFilter(
                        "CIGaussianBlur",
                        parameters: [kCIInputRadiusKey: max(1.0, settings.blurRadius)]
                    ).cropped(to: bounds)
                } else {
                    filtered = original.clampedToExtent().applyingFilter(
                        "CIPixellate",
                        parameters: [
                            kCIInputScaleKey: max(2.0, settings.pixelSize),
                            kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
                        ]
                    ).cropped(to: bounds)
                }
                
                guard let renderedPart = imageContext.createCGImage(filtered, from: bounds) else {
                    throw FileveroError.failed("Could not render the redaction.")
                }
                context.draw(renderedPart, in: target)
            }
        }
        
        guard let output = context.makeImage() else {
            throw FileveroError.failed("Could not redact image.")
        }
        return output
    }

    public static func recognizedRegions(
        _ input: URL,
        faces: Bool = true,
        text: Bool = true,
        padding: Double = 0.02
    ) throws -> [DetectedImageRegion] {
        try recognizedRegions(load(input), faces: faces, text: text, padding: padding)
    }

    public static func recognizedRegions(
        _ image: CGImage,
        faces: Bool = true,
        text: Bool = true,
        padding: Double = 0.02
    ) throws -> [DetectedImageRegion] {
        guard padding.isFinite, padding >= 0 else {
            throw FileveroError.invalidInput("Detection padding must be nonnegative.")
        }
        
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        
        if faces { requests.append(faceRequest) }
        if text { requests.append(textRequest) }
        guard !requests.isEmpty else { return [] }
        
        try VNImageRequestHandler(cgImage: image).perform(requests)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        
        func toPixels(_ box: CGRect) -> EditRect {
            let r = CGRect(
                x: box.minX * Double(image.width),
                y: (1.0 - box.maxY) * Double(image.height),
                width: box.width * Double(image.width),
                height: box.height * Double(image.height)
            )
            let expanded = r.insetBy(
                dx: -max(2.0, r.width * padding),
                dy: -max(2.0, r.height * padding)
            ).intersection(bounds).integral
            return EditRect(x: expanded.minX, y: expanded.minY, width: expanded.width, height: expanded.height)
        }
        
        var regions = (faces ? faceRequest.results ?? [] : []).map {
            DetectedImageRegion(kind: .face, rect: toPixels($0.boundingBox), confidence: Double($0.confidence))
        }
        regions += (text ? textRequest.results ?? [] : []).map { result in
            DetectedImageRegion(
                kind: .text,
                rect: toPixels(result.boundingBox),
                confidence: Double(result.topCandidates(1).first?.confidence ?? result.confidence),
                text: result.topCandidates(1).first?.string
            )
        }
        return regions
    }
}

