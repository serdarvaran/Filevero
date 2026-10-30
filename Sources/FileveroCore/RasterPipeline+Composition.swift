import CoreGraphics
import CoreImage
import Foundation

extension RasterPipeline {
    public static func framedImage(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        try frame(image, options: options)
    }

    static func frame(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        var settings = options.imageFrame ?? ImageFrameOptions()
        if options.imageFrame == nil {
            settings.padding = options.padding
            settings.cornerRadius = Double(options.cornerRadius)
            settings.backgroundColor = options.backgroundColor
            settings.shadowRadius = 0
        }
        
        guard [
            settings.position.x, settings.position.y, settings.imageScale, settings.cornerRadius,
            settings.backgroundBlur, settings.shadowRadius, settings.shadowOpacity, settings.gradientAngle,
        ].allSatisfy(\.isFinite), settings.imageScale > 0
        else {
            throw FileveroError.invalidInput("Frame settings must be finite, and image scale must be positive.")
        }
        
        let padding = max(0, settings.padding)
        guard padding <= 32000, settings.imageScale <= 100 else {
            throw FileveroError.invalidInput("Frame padding or image scale is too large.")
        }
        
        for value in [settings.width, settings.height].compactMap({ $0 }) {
            guard value > 0, value <= 32000 else {
                throw FileveroError.invalidInput("Canvas dimensions must be between 1 and 32,000 pixels.")
            }
        }
        
        var width = settings.width ?? image.width + padding * 2
        var height = settings.height ?? image.height + padding * 2
        
        func validateDimension(_ number: Double) throws -> Int {
            guard number.isFinite, number >= 1, number <= 32000 else {
                throw FileveroError.invalidInput("Canvas dimensions must be between 1 and 32,000 pixels.")
            }
            return Int(number.rounded(.up))
        }
        
        if let ratio = settings.aspectRatio {
            guard ratio.isFinite, ratio > 0 else {
                throw FileveroError.invalidInput("Canvas aspect ratio must be positive.")
            }
            if settings.width != nil && settings.height == nil {
                height = try validateDimension(Double(width) / ratio)
            } else if settings.height != nil && settings.width == nil {
                width = try validateDimension(Double(height) * ratio)
            } else if settings.width == nil && settings.height == nil {
                if Double(width) / Double(height) < ratio {
                    width = try validateDimension(Double(height) * ratio)
                } else {
                    height = try validateDimension(Double(width) / ratio)
                }
            }
        }
        
        let context = try canvas(width, height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(color(settings.backgroundColor))
        context.fill(bounds)
        
        switch settings.backdrop {
        case .solid:
            break
        case .gradient:
            let colors = settings.gradientColors.isEmpty
                ? [settings.backgroundColor, settings.backgroundColor]
                : settings.gradientColors
            guard let gradient = CGGradient(
                colorsSpace: imageColorSpace,
                colors: colors.map(color) as CFArray,
                locations: nil
            ) else {
                throw FileveroError.invalidInput("Choose gradient colors.")
            }
            let angle = settings.gradientAngle * .pi / 180.0
            let dx = cos(angle) * Double(width) / 2.0
            let dy = sin(angle) * Double(height) / 2.0
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: Double(width) / 2.0 - dx, y: Double(height) / 2.0 - dy),
                end: CGPoint(x: Double(width) / 2.0 + dx, y: Double(height) / 2.0 + dy),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        case .image:
            guard let url = settings.backgroundImage else {
                throw FileveroError.invalidInput("Choose a background image.")
            }
            var backdrop = try load(url)
            if settings.backgroundBlur > 0 {
                let backdropImage = CIImage(cgImage: backdrop)
                let blur = backdropImage.clampedToExtent().applyingFilter(
                    "CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.backgroundBlur]
                ).cropped(to: backdropImage.extent)
                guard let rendered = imageContext.createCGImage(blur, from: backdropImage.extent) else {
                    throw FileveroError.failed("Could not blur background.")
                }
                backdrop = rendered
            }
            drawFitted(backdrop, in: bounds, context: context, fit: .fill)
        }
        
        let availableWidth = max(1, width - padding * 2)
        let availableHeight = max(1, height - padding * 2)
        let scale = min(
            1.0,
            min(Double(availableWidth) / Double(image.width), Double(availableHeight) / Double(image.height))
        ) * settings.imageScale
        
        let imageWidth = Double(image.width) * scale
        let imageHeight = Double(image.height) * scale
        let x = (Double(width) - imageWidth) * max(0.0, min(1.0, settings.position.x))
        let top = (Double(height) - imageHeight) * max(0.0, min(1.0, settings.position.y))
        let r = CGRect(x: x, y: Double(height) - top - imageHeight, width: imageWidth, height: imageHeight)
        let radius = max(0.0, min(settings.cornerRadius, min(r.width, r.height) / 2.0))
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        
        context.saveGState()
        if settings.shadowRadius > 0, settings.shadowOpacity > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -settings.shadowRadius / 4.0),
                blur: settings.shadowRadius,
                color: CGColor(gray: 0, alpha: max(0.0, min(1.0, settings.shadowOpacity)))
            )
        }
        // The layer casts the shadow from the clipped image's own alpha, so transparent areas stay see-through.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: r)
        context.endTransparencyLayer()
        context.restoreGState()
        
        guard let result = context.makeImage() else {
            throw FileveroError.failed("Could not frame image.")
        }
        return result
    }

    static func collage(_ inputs: [URL], options: OperationOptions, token: CancellationToken) throws -> [URL] {
        guard let first = inputs.first else {
            throw FileveroError.invalidInput("Choose images for your collage.")
        }
        if let settings = options.collage {
            let images = try inputs.map { input in
                try token.check()
                return try load(input)
            }
            let output = FileWorkspace.unique(
                for: first,
                extension: "png",
                suffix: " - Collage",
                directory: options.outputDirectory
            )
            try write(collageImage(images, settings: settings), to: output)
            return [output]
        }
        
        let images = try inputs.map(load)
        let columns = max(1, min(inputs.count, options.collageColumns))
        let rows = (inputs.count + columns - 1) / columns
        let cellWidth = options.width ?? 600
        let cellHeight = options.height ?? 600
        let gap = max(0, options.padding)
        let width = columns * cellWidth + (columns + 1) * gap
        let height = rows * cellHeight + (rows + 1) * gap
        
        let context = try canvas(width, height)
        context.setFillColor(color(options.backgroundColor))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        for (index, image) in images.enumerated() {
            try token.check()
            let scale = min(Double(cellWidth) / Double(image.width), Double(cellHeight) / Double(image.height))
            let w = Double(image.width) * scale
            let h = Double(image.height) * scale
            let x = Double(gap + (index % columns) * (cellWidth + gap)) + (Double(cellWidth) - w) / 2.0
            let y = Double(height - gap - (index / columns + 1) * cellHeight - (index / columns) * gap)
                + (Double(cellHeight) - h) / 2.0
            context.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
        }
        
        let output = FileWorkspace.unique(
            for: first,
            extension: "png",
            suffix: " - Collage",
            directory: options.outputDirectory
        )
        try write(context.makeImage()!, to: output)
        return [output]
    }

    public static func collageImage(_ inputs: [CGImage], settings: CollageOptions) throws -> CGImage {
        guard inputs.count >= 2 else {
            throw FileveroError.invalidInput("Choose at least two images for a collage.")
        }
        guard settings.aspectRatio.isFinite, settings.aspectRatio > 0, settings.cornerRadius.isFinite else {
            throw FileveroError.invalidInput("Collage ratio and corner radius must be valid.")
        }
        
        let images: [CGImage]
        if settings.imageOrder.isEmpty {
            images = inputs
        } else {
            guard settings.imageOrder.count == inputs.count, Set(settings.imageOrder) == Set(inputs.indices) else {
                throw FileveroError.invalidInput("Image order must include every image exactly once.")
            }
            images = settings.imageOrder.map { inputs[$0] }
        }
        
        guard settings.width > 0, settings.width <= 32000 else {
            throw FileveroError.invalidInput("Collage dimensions must be between 1 and 32,000 pixels.")
        }
        
        let calculatedHeight = Double(settings.width) / settings.aspectRatio
        if settings.height == nil {
            guard calculatedHeight.isFinite, calculatedHeight >= 1, calculatedHeight <= 32000 else {
                throw FileveroError.invalidInput("Collage dimensions must be between 1 and 32,000 pixels.")
            }
        }
        
        let width = settings.width
        let height = settings.height ?? Int(calculatedHeight.rounded())
        let context = try canvas(width, height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(color(settings.backgroundColor))
        context.fill(bounds)
        
        if let backdrop = settings.backgroundImage {
            drawFitted(try load(backdrop), in: bounds, context: context, fit: .fill)
        }
        
        let padding = Double(max(0, settings.outerPadding))
        let gap = Double(max(0, settings.spacing))
        let area = bounds.insetBy(dx: padding, dy: padding)
        guard area.width > 0, area.height > 0 else {
            throw FileveroError.invalidInput("Collage padding leaves no space for images.")
        }
        
        var cells: [CGRect] = []
        if settings.layout == .featured {
            let featureWidth = (area.width - gap) * 2.0 / 3.0
            let otherWidth = area.width - gap - featureWidth
            let otherHeight = (area.height - gap * Double(images.count - 2)) / Double(images.count - 1)
            guard featureWidth > 0, otherWidth > 0, otherHeight > 0 else {
                throw FileveroError.invalidInput("Reduce collage spacing or increase the canvas.")
            }
            cells.append(CGRect(x: area.minX, y: area.minY, width: featureWidth, height: area.height))
            for index in 1..<images.count {
                cells.append(
                    CGRect(
                        x: area.minX + featureWidth + gap,
                        y: area.maxY - Double(index) * otherHeight - Double(index - 1) * gap,
                        width: otherWidth,
                        height: otherHeight
                    )
                )
            }
        } else {
            let columns = settings.layout == .row
                ? images.count
                : settings.layout == .column ? 1 : max(1, min(images.count, settings.columns))
            let rows = (images.count + columns - 1) / columns
            let cellWidth = (area.width - gap * Double(columns - 1)) / Double(columns)
            let cellHeight = (area.height - gap * Double(rows - 1)) / Double(rows)
            guard cellWidth > 0, cellHeight > 0 else {
                throw FileveroError.invalidInput("Reduce collage spacing or increase the canvas.")
            }
            for index in images.indices {
                cells.append(
                    CGRect(
                        x: area.minX + Double(index % columns) * (cellWidth + gap),
                        y: area.maxY - Double(index / columns + 1) * cellHeight - Double(index / columns) * gap,
                        width: cellWidth,
                        height: cellHeight
                    )
                )
            }
        }
        
        for (img, cell) in zip(images, cells) {
            context.saveGState()
            let radius = max(0.0, min(settings.cornerRadius, min(cell.width, cell.height) / 2.0))
            context.addPath(CGPath(roundedRect: cell, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            drawFitted(img, in: cell, context: context, fit: settings.imageFit)
            context.restoreGState()
        }
        
        guard let result = context.makeImage() else {
            throw FileveroError.failed("Could not create collage.")
        }
        return result
    }
}

