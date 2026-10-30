import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Batch manipulation engine for bulk image operations including watermarking, uniform aspect resizing, and animation/slideshow synthesis.
public enum RasterBatchProcessor {
    private static let rgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func run(
        _ kind: ToolKind,
        inputs: [URL],
        options: OperationOptions,
        token: CancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> [URL] {
        switch kind {
        case .createAnimation:
            return [
                try generateAnimation(
                    inputs,
                    options: options.animation ?? .init(),
                    directory: options.outputDirectory,
                    token: token,
                    progress: progress
                )
            ]
        case .removeLocation:
            var changes = ImageMetadataOptions()
            changes.removeLocation = true
            return try inputs.map {
                try token.check()
                return try ImageEngine.editMetadata($0, changes: changes, options: options, token: token)
            }
        case .watermark, .uniformSize:
            var generatedOutputs: [URL] = []
            for (index, input) in inputs.enumerated() {
                try token.check()
                progress(Double(index) / Double(inputs.count), input.lastPathComponent)
                let loadedImage = try ImageEngine.load(input)
                let transformedImage = kind == .watermark
                    ? try watermarked(loadedImage, options: options.watermark ?? .init())
                    : try uniform(loadedImage, options: options.uniformSize ?? .init())
                let outputDestination = FileWorkspace.unique(
                    for: input,
                    extension: ImageEngine.outputExtension(for: input),
                    suffix: kind == .watermark ? " - Watermarked" : " - Resized",
                    directory: options.outputDirectory
                )
                try ImageEngine.write(transformedImage, to: outputDestination, quality: 0.92)
                generatedOutputs.append(outputDestination)
            }
            return generatedOutputs
        default:
            throw FileveroError.unsupported("\(kind.title) is not an image operation.")
        }
    }

    public static func watermarked(_ image: CGImage, options: WatermarkOptions) throws -> CGImage {
        let context = try createCanvas(image.width, image.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        try drawWatermark(options, in: context, bounds: bounds)
        guard let output = context.makeImage() else {
            throw FileveroError.failed("The watermark could not be added.")
        }
        return output
    }

    public static func drawWatermark(_ options: WatermarkOptions, in context: CGContext, bounds: CGRect) throws {
        guard (0...1).contains(options.opacity), options.scale > 0, options.scale <= 1 else {
            throw FileveroError.invalidInput("Choose an opacity and size between 0 and 100%.")
        }
        let watermarkContent: WatermarkContent
        if let logoURL = options.logo {
            watermarkContent = .image(try ImageEngine.load(logoURL))
        } else {
            let text = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw FileveroError.invalidInput("Enter watermark text or choose a logo.")
            }
            watermarkContent = .text(text, ImageEngine.color(options.color))
        }
        
        let desiredWidth = bounds.width * options.scale
        let computedSize = watermarkContent.size(forWidth: desiredWidth)
        let margin = min(bounds.width, bounds.height) * 0.03
        
        context.saveGState()
        context.setAlpha(options.opacity)
        
        if options.position == .tiled {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.rotate(by: -.pi / 6)
            let diagonal = hypot(bounds.width, bounds.height)
            let stepX = computedSize.width * 1.6
            let stepY = max(computedSize.height * 3, 1)
            var y = -diagonal / 2
            while y < diagonal / 2 {
                var x = -diagonal / 2
                while x < diagonal / 2 {
                    watermarkContent.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: computedSize), context: context)
                    x += stepX
                }
                y += stepY
            }
        } else {
            let x: CGFloat
            let y: CGFloat
            switch options.position {
            case .topLeft, .bottomLeft: x = bounds.minX + margin
            case .topRight, .bottomRight: x = bounds.maxX - margin - computedSize.width
            default: x = bounds.midX - computedSize.width / 2
            }
            switch options.position {
            case .topLeft, .top, .topRight: y = bounds.maxY - margin - computedSize.height
            case .bottomLeft, .bottom, .bottomRight: y = bounds.minY + margin
            default: y = bounds.midY - computedSize.height / 2
            }
            watermarkContent.draw(in: CGRect(x: x, y: y, width: computedSize.width, height: computedSize.height), context: context)
        }
        context.restoreGState()
    }

    private enum WatermarkContent {
        case text(String, CGColor)
        case image(CGImage)
        
        func size(forWidth width: CGFloat) -> CGSize {
            switch self {
            case .image(let img):
                return CGSize(width: width, height: width * CGFloat(img.height) / CGFloat(max(1, img.width)))
            case .text(let txt, _):
                let (lineWidth, ascent, descent) = Self.metrics(txt, fontSize: 100)
                let fontSize = 100 * width / max(1, lineWidth)
                return CGSize(width: width, height: (ascent + descent) * fontSize / 100)
            }
        }
        
        func draw(in rect: CGRect, context: CGContext) {
            switch self {
            case .image(let img):
                context.interpolationQuality = .high
                context.draw(img, in: rect)
            case .text(let txt, let clr):
                let (lineWidth, _, descent) = Self.metrics(txt, fontSize: 100)
                let fontSize = 100 * rect.width / max(1, lineWidth)
                let line = Self.buildLine(txt, fontSize: fontSize, color: clr)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * fontSize / 100)
                CTLineDraw(line, context)
            }
        }
        
        static func buildLine(_ text: String, fontSize: CGFloat, color: CGColor? = nil) -> CTLine {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil) as Any
            ]
            if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        
        static func metrics(_ text: String, fontSize: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(buildLine(text, fontSize: fontSize), &ascent, &descent, nil)
            return (CGFloat(width), ascent, descent)
        }
    }

    public static func uniform(_ image: CGImage, options: UniformSizeOptions) throws -> CGImage {
        guard (16...16000).contains(options.width), (16...16000).contains(options.height) else {
            throw FileveroError.invalidInput("Choose a width and height between 16 and 16000 pixels.")
        }
        let context = try createCanvas(options.width, options.height)
        let bounds = CGRect(x: 0, y: 0, width: options.width, height: options.height)
        context.setFillColor(ImageEngine.color(options.background))
        context.fill(bounds)
        let sx = bounds.width / CGFloat(image.width)
        let sy = bounds.height / CGFloat(image.height)
        let scale = options.mode == .fill ? max(sx, sy) : min(sx, sy)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        )
        guard let result = context.makeImage() else {
            throw FileveroError.failed("The image could not be resized.")
        }
        return result
    }

    static func calculateFrameSize(_ inputs: [URL], options: AnimationOptions) throws -> UniformSizeOptions {
        guard inputs.count >= 2 else { throw FileveroError.invalidInput("Choose two or more images.") }
        guard (64...4096).contains(options.maxDimension) else {
            throw FileveroError.invalidInput("Choose a frame size between 64 and 4096 pixels.")
        }
        let first = try ImageEngine.load(inputs[0])
        let scale = min(1.0, Double(options.maxDimension) / Double(max(first.width, first.height)))
        var settings = UniformSizeOptions()
        settings.width = max(16, Int(Double(first.width) * scale) / 2 * 2)
        settings.height = max(16, Int(Double(first.height) * scale) / 2 * 2)
        settings.background = options.background
        return settings
    }

    private static func generateAnimation(
        _ inputs: [URL],
        options: AnimationOptions,
        directory: URL?,
        token: CancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> URL {
        guard options.secondsPerImage.isFinite, (0.05...60).contains(options.secondsPerImage) else {
            throw FileveroError.invalidInput("Show each image for 0.05 to 60 seconds.")
        }
        let size = try calculateFrameSize(inputs, options: options)
        
        func renderFrame(_ index: Int) throws -> CGImage {
            try token.check()
            progress(Double(index) / Double(inputs.count) * 0.8, "Preparing frames…")
            return try uniform(ImageEngine.load(inputs[index]), options: size)
        }
        
        switch options.format {
        case "gif":
            let output = FileWorkspace.unique(
                for: inputs[0],
                extension: "gif",
                suffix: " - Animation",
                directory: directory
            )
            guard let destination = CGImageDestinationCreateWithURL(
                output as CFURL,
                UTType.gif.identifier as CFString,
                inputs.count,
                nil
            ) else {
                throw FileveroError.failed("The GIF could not be created.")
            }
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            )
            for idx in inputs.indices {
                CGImageDestinationAddImage(
                    destination,
                    try renderFrame(idx),
                    [
                        kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFDelayTime: options.secondsPerImage,
                            kCGImagePropertyGIFUnclampedDelayTime: options.secondsPerImage,
                        ]
                    ] as CFDictionary
                )
            }
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: output)
                throw FileveroError.failed("The GIF could not be saved.")
            }
            return output
        case "mp4":
            let workDir = try FileWorkspace.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: workDir) }
            for idx in inputs.indices {
                try ImageEngine.write(
                    try renderFrame(idx),
                    to: workDir.appendingPathComponent(String(format: "frame-%05d.png", idx)),
                    quality: 1.0
                )
            }
            let output = FileWorkspace.unique(
                for: inputs[0],
                extension: "mp4",
                suffix: " - Slideshow",
                directory: directory
            )
            try MediaEngine.slideshow(
                frames: workDir,
                count: inputs.count,
                secondsPerImage: options.secondsPerImage,
                to: output,
                token: token,
                progress: progress
            )
            return output
        default:
            throw FileveroError.invalidInput("Choose GIF or MP4.")
        }
    }

    private static func createCanvas(_ width: Int, _ height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 32000, height <= 32000,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: rgbColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw FileveroError.failed("Could not allocate image canvas.")
        }
        return context
    }
}

public typealias ImageBatchTools = RasterBatchProcessor

