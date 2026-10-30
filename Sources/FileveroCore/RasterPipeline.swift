import AppKit
import CoreImage
import Foundation
import ImageIO
#if canImport(Vision)
import Vision
#endif

/// Core image decoding, transformation, filtering, and re-encoding raster pipeline.
public enum RasterPipeline {
    static let imageColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let imageContext = CIContext(options: [.cacheIntermediates: false])

    public static func load(_ url: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(
               source, 0,
               [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 32000,
               ] as CFDictionary
           ) {
            return image
        }
        
        if let nsImage = NSImage(contentsOf: url),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        
        // Fallback to FFmpeg decoder for animated frames, specialized codecs, or corrupted headers
        let tempDirectory = try FileWorkspace.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let png = tempDirectory.appendingPathComponent("decoded.png")
        
        try ExecutionPipeline.run(
            try ExternalToolResolver.executable("ffmpeg"),
            ["-v", "error", "-i", url.path, "-frames:v", "1", png.path]
        )
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FileveroError.invalidInput("This image could not be decoded.")
        }
        return cgImage
    }

    public static func convert(
        _ input: URL,
        to format: String,
        options: OperationOptions,
        token: CancellationToken
    ) throws -> [URL] {
        try token.check()
        if format == "pdf" {
            return try PDFEngine.create(inputs: [input], options: options, token: token)
        }
        
        let image = try fitting(load(input), within: options.maxImageDimension)
        let output = FileWorkspace.unique(for: input, extension: format, directory: options.outputDirectory)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        
        let metadata = options.preserveMetadata
            ? CGImageSourceCreateWithURL(input as CFURL, nil).map { imageProperties($0, input: input) as CFDictionary }
            : nil
            
        try write(image, to: output, quality: options.quality, metadata: metadata)
        if options.preserveMetadata {
            try ImageExifPipeline.copyMetadata(from: input, to: output, token: token)
        }
        complete = true
        return [output]
    }

    public static func write(
        _ image: CGImage,
        to url: URL,
        quality: Double = 0.8,
        metadata: CFDictionary? = nil
    ) throws {
        let ext = url.pathExtension.lowercased()
        let typeIdentifier: String
        switch ext {
        case "jpg", "jpeg": typeIdentifier = "public.jpeg"
        case "png": typeIdentifier = "public.png"
        case "heic", "heif": typeIdentifier = "public.heic"
        case "tiff", "tif": typeIdentifier = "public.tiff"
        case "bmp": typeIdentifier = "com.microsoft.bmp"
        case "gif": typeIdentifier = "com.compuserve.gif"
        case "webp": typeIdentifier = "org.webmproject.webp"
        case "avif": typeIdentifier = "public.avif"
        default: throw FileveroError.unsupported("Unsupported image output: \(ext)")
        }
        
        if (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(typeIdentifier),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil) {
            var properties = (metadata as? [CFString: Any]) ?? [:]
            properties[kCGImageDestinationLossyCompressionQuality] = max(0.01, min(1.0, quality))
            properties[kCGImagePropertyOrientation] = 1
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw FileveroError.failed("Could not write \(url.lastPathComponent)")
            }
        } else {
            let tempDir = try FileWorkspace.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let png = tempDir.appendingPathComponent("image.png")
            try write(image, to: png, quality: 1.0)
            
            var args = ["-v", "error", "-i", png.path, "-frames:v", "1"]
            if ext == "webp" {
                args += ["-c:v", "libwebp", "-quality", String(Int(quality * 100))]
            }
            if ext == "avif" {
                args += [
                    "-c:v", "libaom-av1", "-still-picture", "1", "-cpu-used", "6", "-crf",
                    String(Int((1 - quality) * 50) + 8),
                ]
            }
            args += [url.path]
            try ExecutionPipeline.run(try ExternalToolResolver.executable("ffmpeg"), args)
        }
    }

    public static func tool(
        _ kind: ToolKind,
        inputs: [URL],
        options: OperationOptions,
        token: CancellationToken
    ) throws -> [URL] {
        if kind == .createCollage {
            return try collage(inputs, options: options, token: token)
        }
        var outputs: [URL] = []
        
        for input in inputs {
            do {
                try token.check()
                if kind == .removeMetadata {
                    if let changes = options.imageMetadata {
                        outputs.append(try editMetadata(input, changes: changes, options: options, token: token))
                        continue
                    }
                    if !options.metadata.isEmpty {
                        var changes = ImageMetadataOptions()
                        changes.updates = options.metadata
                        outputs.append(try editMetadata(input, changes: changes, options: options, token: token))
                        continue
                    }
                    var changes = ImageMetadataOptions()
                    changes.removeAll = true
                    outputs.append(try editMetadata(input, changes: changes, options: options, token: token))
                    continue
                }
                
                var image = try load(input)
                let transparentFrame = kind == .frameImage
                    && color(options.imageFrame?.backgroundColor ?? options.backgroundColor).alpha < 1.0
                let ext = transparentFrame ? "png" : outputExtension(for: input)
                    
                let suffix: String
                switch kind {
                case .compress:
                    outputs += try compress(input, options: options, token: token)
                    continue
                case .cropImage:
                    image = try preview(image, tool: .cropImage, options: options)
                    suffix = " - Cropped"
                case .editImage:
                    image = try edit(image, options: options)
                    suffix = " - Edited"
                case .annotateImage:
                    image = try annotate(image, options: options)
                    suffix = " - Annotated"
                case .redactImage:
                    image = try redact(image, options: options)
                    suffix = " - Redacted"
                case .frameImage:
                    image = try frame(image, options: options)
                    suffix = " - Framed"
                case .removeBackground:
                    image = try removeBackground(from: image)
                    suffix = " - No Background"
                default:
                    throw FileveroError.unsupported("\(kind.title) is not an image operation.")
                }
                
                let output = FileWorkspace.unique(
                    for: input,
                    extension: (kind == .annotateImage || kind == .removeBackground) ? "png" : ext,
                    suffix: suffix,
                    directory: options.outputDirectory
                )
                try write(image, to: output, quality: options.quality)
                outputs.append(output)
            } catch FileveroError.invalidInput(let message) where kind == .cropImage || kind == .redactImage {
                throw FileveroError.invalidInput("\(input.lastPathComponent): \(message)")
            } catch FileveroError.cancelled {
                throw FileveroError.cancelled
            } catch let error where kind == .cropImage || kind == .redactImage {
                throw FileveroError.failed("\(input.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outputs
    }

    public static func removeBackground(from image: CGImage) throws -> CGImage {
        #if canImport(Vision)
        if #available(macOS 14.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first else {
                throw FileveroError.failed("No subject was detected in this image.")
            }
            let pixelBuffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgResult = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
                throw FileveroError.failed("Could not produce a transparent background image.")
            }
            return cgResult
        } else {
            throw FileveroError.unsupported("AI Background Removal requires macOS 14 or later.")
        }
        #else
        throw FileveroError.unsupported("Vision framework is unavailable.")
        #endif
    }

    public static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width <= 32000, height <= 32000,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: imageColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw FileveroError.invalidInput("Image dimensions must be between 1 and 32,000 pixels.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw FileveroError.failed("Could not resize image.")
        }
        return result
    }

    public static func preview(_ image: CGImage, tool: ToolKind = .editImage, options: OperationOptions) throws -> CGImage {
        switch tool {
        case .editImage: return try edit(image, options: options)
        case .annotateImage: return try annotate(image, options: options)
        case .redactImage: return try redact(image, options: options)
        case .frameImage: return try frame(image, options: options)
        case .removeBackground: return try removeBackground(from: image)
        case .cropImage:
            guard let crop = options.crop else { throw FileveroError.invalidInput("Choose a crop rectangle.") }
            guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite) else {
                throw FileveroError.invalidInput("Crop coordinates must be finite.")
            }
            guard crop.x >= 0, crop.y >= 0, crop.width >= 1, crop.height >= 1 else {
                throw FileveroError.invalidInput("Crop origins must be nonnegative and dimensions at least 1 × 1 pixel.")
            }
            let width = Double(image.width)
            let height = Double(image.height)
            guard crop.x <= width, crop.y <= height, crop.width <= width - crop.x, crop.height <= height - crop.y else {
                throw FileveroError.invalidInput(
                    "The crop rectangle must fit completely inside the \(image.width) × \(image.height) pixel image."
                )
            }
            let r = CGRect(
                x: crop.x.rounded(.down), y: crop.y.rounded(.down),
                width: crop.width.rounded(.down), height: crop.height.rounded(.down)
            )
            guard let result = image.cropping(to: r) else {
                throw FileveroError.invalidInput("The crop rectangle could not be read from the image.")
            }
            return try resizeUsingOptions(result, options: options)
        default:
            throw FileveroError.unsupported("\(tool.title) does not have a single-image preview.")
        }
    }

    public static func editedImage(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        try edit(image, options: options)
    }

    static let writableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "webp", "avif",
    ]

    /// ImageIO reads camera RAW but cannot write it, so edited RAW files are saved as JPEG.
    static func outputExtension(for input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        if ["svg", "gif"].contains(ext) { return "png" }
        return writableExtensions.contains(ext) ? input.pathExtension : "jpg"
    }

    public static let resizableExtensions: Set<String> = [
        "jpg", "png", "heic", "tiff", "webp", "bmp", "avif", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"
    ]

    static func fitting(_ image: CGImage, within limit: Int?) throws -> CGImage {
        guard let limit else { return image }
        guard (1...32000).contains(limit) else {
            throw FileveroError.invalidInput("Image dimensions must be between 1 and 32,000 pixels.")
        }
        let longest = max(image.width, image.height)
        guard longest > limit else { return image }
        let scale = Double(limit) / Double(longest)
        return try resized(
            image,
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
    }

    static func resizeUsingOptions(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        guard options.width != nil || options.height != nil else { return image }
        for value in [options.width, options.height].compactMap({ $0 }) {
            guard value > 0, value <= 32000 else {
                throw FileveroError.invalidInput("Image dimensions must be between 1 and 32,000 pixels.")
            }
        }
        let ratio = Double(image.height) / Double(image.width)
        let width = options.width ?? Int(Double(options.height!) / ratio)
        let height = options.height ?? Int(Double(width) * ratio)
        return try resized(image, width: width, height: height)
    }

    static func edit(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        let a = options.imageAdjustments
        let values = [
            a.exposure, a.brightness, a.contrast, a.highlights, a.shadows, a.whites, a.blacks, a.gamma, a.temperature,
            a.tint, a.saturation, a.vibrance, a.hue, a.clarity, a.texture, a.fade, a.blur, a.sharpen, a.dehaze, a.grain,
            a.noiseReduction, a.vignette, options.brightness, options.contrast, options.saturation,
        ]
        guard values.allSatisfy(\.isFinite), a.gamma > 0 else {
            throw FileveroError.invalidInput("Image adjustments must be finite and gamma must be positive.")
        }
        var ciImage = CIImage(cgImage: image)
        let bounds = ciImage.extent
        
        if a.noiseReduction > 0 {
            ciImage = ciImage.applyingFilter(
                "CINoiseReduction",
                parameters: ["inputNoiseLevel": min(1.0, a.noiseReduction) * 0.1, "inputSharpness": 0]
            )
        }
        if a.exposure != 0 {
            ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: min(10.0, max(-10.0, a.exposure))])
        }
        if a.temperature != 0 || a.tint != 0 {
            ciImage = ciImage.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(
                        x: 6500 + max(-1.0, min(1.0, a.temperature)) * 3000,
                        y: max(-1.0, min(1.0, a.tint)) * 100
                    ),
                ]
            )
        }
        ciImage = ciImage.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: options.brightness + a.brightness,
                kCIInputContrastKey: max(0.0, options.contrast * a.contrast),
                kCIInputSaturationKey: max(0.0, options.saturation * a.saturation),
            ]
        )
        if a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0 {
            let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
            var ys = xs.map { x in
                max(
                    0.0,
                    min(
                        1.0,
                        x + a.blacks * 0.25 * pow(1 - x, 4) + a.whites * 0.25 * pow(x, 4)
                            + a.shadows * 0.5 * 4 * x * pow(1 - x, 3) + a.highlights * 0.5 * 4 * pow(x, 3) * (1 - x)
                    )
                )
            }
            for index in 1..<ys.count { ys[index] = max(ys[index - 1], ys[index]) }
            var parameters: [String: Any] = [:]
            for index in xs.indices { parameters["inputPoint\(index)"] = CIVector(x: xs[index], y: ys[index]) }
            ciImage = ciImage.applyingFilter("CIToneCurve", parameters: parameters)
        }
        if a.gamma != 1 {
            ciImage = ciImage.applyingFilter("CIGammaAdjust", parameters: ["inputPower": max(0.1, min(5.0, a.gamma))])
        }
        if a.vibrance != 0 {
            ciImage = ciImage.applyingFilter("CIVibrance", parameters: ["inputAmount": max(-1.0, min(1.0, a.vibrance))])
        }
        if a.hue != 0 {
            ciImage = ciImage.applyingFilter("CIHueAdjust", parameters: ["inputAngle": a.hue * .pi / 180.0])
        }
        if a.dehaze != 0 {
            ciImage = ciImage.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputContrastKey: 1 + max(-1.0, min(1.0, a.dehaze)) * 0.65,
                    kCIInputBrightnessKey: -a.dehaze * 0.045,
                    kCIInputSaturationKey: 1 + a.dehaze * 0.12,
                ]
            )
        }
        if a.clarity > 0 {
            ciImage = ciImage.applyingFilter(
                "CIUnsharpMask", parameters: [kCIInputRadiusKey: 4, kCIInputIntensityKey: min(1.0, a.clarity) * 1.5]
            )
        }
        if a.clarity < 0 {
            ciImage = ciImage.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: [kCIInputRadiusKey: min(1.0, -a.clarity) * 3]
            ).cropped(to: bounds)
        }
        if a.sharpen > 0 {
            ciImage = ciImage.applyingFilter(
                "CISharpenLuminance", parameters: [kCIInputSharpnessKey: min(2.0, a.sharpen)]
            )
        }
        if a.texture > 0 {
            ciImage = ciImage.applyingFilter(
                "CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.5, kCIInputIntensityKey: min(1.0, a.texture) * 2]
            )
        }
        if a.texture < 0 {
            ciImage = ciImage.applyingFilter(
                "CINoiseReduction", parameters: ["inputNoiseLevel": min(1.0, -a.texture) * 0.15, "inputSharpness": 0]
            )
        }
        if a.fade > 0 {
            let amount = min(1.0, a.fade)
            let scale = 1.0 - amount * 0.4
            let bias = amount * 0.15
            ciImage = ciImage.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
                ]
            )
        }
        if a.blur > 0 {
            ciImage = ciImage.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: [kCIInputRadiusKey: min(100.0, a.blur)]
            ).cropped(to: bounds)
        }
        if a.grain > 0, let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let monochrome = CIVector(x: 0.3333, y: 0.3333, z: 0.3334, w: 0)
            let grain = random.cropped(to: bounds).applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": monochrome, "inputGVector": monochrome, "inputBVector": monochrome,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: min(1.0, a.grain) * 0.25),
                ]
            )
            ciImage = grain.composited(over: ciImage)
        }
        if a.vignette != 0 {
            ciImage = ciImage.applyingFilter(
                "CIVignette",
                parameters: [
                    kCIInputIntensityKey: max(-2.0, min(2.0, a.vignette)),
                    kCIInputRadiusKey: Double(min(image.width, image.height)) * 0.5,
                ]
            )
        }
        ciImage = ciImage.cropped(to: bounds)
        if options.flipHorizontal {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        let rotation = ((options.rotation % 360) + 360) % 360
        switch rotation {
        case 0: break
        case 90: ciImage = ciImage.oriented(.right)
        case 180: ciImage = ciImage.oriented(.down)
        case 270: ciImage = ciImage.oriented(.left)
        default: ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180.0))
        }
        guard let output = imageContext.createCGImage(ciImage, from: ciImage.extent.integral) else {
            throw FileveroError.failed("Could not edit image.")
        }
        return try resizeUsingOptions(output, options: options)
    }

    static func canvas(_ width: Int, _ height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 32000, height <= 32000,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: imageColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw FileveroError.failed("Could not allocate image canvas.") }
        return context
    }

    public static func color(_ hex: String) -> CGColor {
        var digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        let n = UInt64(digits, radix: 16) ?? 0xFFFFFF
        if digits.count == 8 {
            return CGColor(
                colorSpace: imageColorSpace,
                components: [
                    CGFloat((n >> 24) & 255) / 255.0, CGFloat((n >> 16) & 255) / 255.0,
                    CGFloat((n >> 8) & 255) / 255.0, CGFloat(n & 255) / 255.0,
                ]
            )!
        }
        return CGColor(
            colorSpace: imageColorSpace,
            components: [
                CGFloat((n >> 16) & 255) / 255.0, CGFloat((n >> 8) & 255) / 255.0,
                CGFloat(n & 255) / 255.0, 1.0,
            ]
        )!
    }

    public static func compress(_ input: URL, options: OperationOptions, token: CancellationToken) throws -> [URL] {
        try token.check()
        var image = try load(input)
        let originalWidth = image.width
        let originalHeight = image.height
        image = try resizeUsingOptions(image, options: options)
        let inputSize = Int64((try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        if let percent = options.percentage {
            guard percent.isFinite, percent > 0, percent < 100 else {
                throw FileveroError.invalidInput("Percentage reduction must be greater than 0 and less than 100.")
            }
        }
        let target = options.targetBytes ?? options.percentage.map { Int64(Double(inputSize) * (1 - $0 / 100.0)) }
        if let target {
            guard target > 0 else { throw FileveroError.invalidInput("Choose a positive target file size.") }
        }
        let ext = ["jpg", "jpeg", "heic", "webp", "avif", "png"].contains(input.pathExtension.lowercased())
            ? input.pathExtension
            : "jpg"
        let output = FileWorkspace.unique(
            for: input,
            extension: ext,
            suffix: " - Compressed",
            directory: options.outputDirectory
        )
        var quality = max(0.01, min(1.0, options.quality))
        for iteration in 0..<24 {
            try token.check()
            try? FileManager.default.removeItem(at: output)
            try write(image, to: output, quality: quality)
            let size = ((try FileManager.default.attributesOfItem(atPath: output.path))[.size] as? NSNumber)?.int64Value ?? 0
            if target == nil || size <= target! {
                if image.width == originalWidth, image.height == originalHeight {
                    try FileWorkspace.retainSmallerOriginal(input, output: output, target: target)
                }
                return [output]
            }
            if quality > 0.15 && !["png"].contains(ext.lowercased()) {
                quality *= 0.72
            } else {
                image = try resized(
                    image,
                    width: max(1, Int(Double(image.width) * 0.8)),
                    height: max(1, Int(Double(image.height) * 0.8))
                )
            }
            if iteration == 23 {
                try? FileManager.default.removeItem(at: output)
                throw FileveroError.failed("The requested file size could not be reached. Choose a larger target.")
            }
        }
        return [output]
    }
}

public typealias ImageEngine = RasterPipeline

