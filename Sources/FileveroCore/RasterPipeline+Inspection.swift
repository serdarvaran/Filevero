import Foundation
import ImageIO
import Vision

extension RasterPipeline {
    public static func metadata(_ input: URL) -> [String: String] {
        (try? readMetadata(input)) ?? [:]
    }

    /// Complete metadata extraction combining CoreGraphics properties and ExifTool extended packets.
    public static func readMetadata(_ input: URL, token: CancellationToken = .init()) throws -> [String: String] {
        try token.check()
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else {
            throw FileveroError.invalidInput("This image's metadata could not be read.")
        }
        
        let props = imageProperties(source, input: input)
        var result: [String: String] = [:]
        
        func flattenDict(_ dict: [String: Any], prefix: String) {
            for (k, v) in dict {
                if let sub = v as? [String: Any] {
                    flattenDict(sub, prefix: prefix + k + ".")
                } else {
                    result[prefix + k] = "\(v)"
                }
            }
        }
        
        flattenDict(props, prefix: "")
        let extra = try ImageExifPipeline.fields(input, token: token)
        result.merge(extra) { _, new in new }
        try token.check()
        return result
    }

    static func imageProperties(_ source: CGImageSource, input: URL) -> [String: Any] {
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let format = input.pathExtension.lowercased()
        var exif: Data?
        
        if ["webp", "jpg", "jpeg", "tiff", "tif"].contains(format), let data = try? Data(contentsOf: input) {
            if format == "webp" {
                exif = try? WebPContainerCodec.chunks(data).first(where: { $0.name == "EXIF" })?.payload
            } else if format == "jpg" || format == "jpeg" {
                exif = try? WebPContainerCodec.exifPayload(fromJPEG: data)
            } else {
                exif = data
            }
        }
        
        if let exif {
            let recovered = WebPContainerCodec.tiffTextFields(exif)
            if !recovered.isEmpty {
                var tiff = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
                for (key, value) in recovered { tiff[key] = value }
                properties[kCGImagePropertyTIFFDictionary as String] = tiff
            }
        }
        return properties
    }

    public static func editMetadata(
        _ input: URL,
        changes: ImageMetadataOptions,
        options: OperationOptions = .init(),
        token: CancellationToken = .init()
    ) throws -> URL {
        try ImageExifPipeline.edit(input, changes: changes, options: options, token: token)
    }

    public static func qrCodes(_ input: URL) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: load(input)).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}

