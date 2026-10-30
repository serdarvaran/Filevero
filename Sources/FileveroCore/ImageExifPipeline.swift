import CryptoKit
import Foundation
import ImageIO

/// Metadata-only inspection, transfer, and editing pipeline utilizing embedded ExifTool instances.
/// Validates hash integrity before and after operations to guarantee raw pixel payload remains untouched.
public enum ImageExifPipeline {
    private static let supportedImageFormats: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "avif",
        "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf",
    ]
    
    private static let appearanceTagNames: Set<String> = [
        "Orientation", "ImageWidth", "ImageHeight", "ExifImageWidth", "ExifImageHeight", "ColorSpace", "Gamma",
        "WhitePoint", "PrimaryChromaticities", "YCbCrCoefficients", "YCbCrPositioning", "BitsPerSample",
        "SamplesPerPixel", "Compression", "PhotometricInterpretation", "PlanarConfiguration", "StripOffsets",
        "StripByteCounts", "RowsPerStrip", "TileOffsets", "TileByteCounts", "YCbCrSubSampling", "AnimationIterations",
        "LoopCount", "FrameCount", "Duration",
    ]

    public static func fields(_ input: URL, token: CancellationToken = .init()) throws -> [String: String] {
        let rawDict = try readMetadataDictionary(input, token: token)
        var parsedFields: [String: String] = [:]
        
        for (tagKey, tagValue) in rawDict {
            guard tagKey != "SourceFile", let colonIdx = tagKey.firstIndex(of: ":") else { continue }
            let group = String(tagKey[..<colonIdx])
            guard !["File", "System", "ExifTool", "Composite"].contains(group) else { continue }
            parsedFields[formatDisplayKey(tagKey)] = formatDisplayValue(tagValue)
        }
        
        if let packetData = try? runToolProcess(["-b", "-XMP", input.path], token: token).output,
           let customFields = try? XMPMetadataEditor.fields(packetData) {
            for (key, val) in customFields where !parsedFields.keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                parsedFields[key] = val
            }
        }
        return parsedFields
    }

    public static func isWritable(_ displayKey: String) -> Bool {
        guard let fullTag = try? resolveTagName(displayKey), let colonIdx = fullTag.lastIndex(of: ":") else { return false }
        let group = String(fullTag[..<colonIdx])
        let name = String(fullTag[fullTag.index(after: colonIdx)...])
        guard !["File", "System", "ExifTool", "Composite", "ICC_Profile", "JFIF", "PNG", "GIF", "RIFF", "VP8", "VP8L"].contains(group),
              !appearanceTagNames.contains(name)
        else { return false }
        return true
    }

    public static func copyMetadata(from source: URL, to output: URL, token: CancellationToken) throws {
        guard supportedImageFormats.contains(source.pathExtension.lowercased()),
              supportedImageFormats.contains(output.pathExtension.lowercased())
        else { return }
        
        let targetDataHash = try encodedImageHash(output, token: token)
        let sourceDict = try readMetadataDictionary(source, token: token)
        
        _ = try runToolProcess(
            [
                "-overwrite_original", "-TagsFromFile", source.path, "-EXIF:all", "-XMP", "-IPTC:all", "--Orientation",
                "-Orientation#=1", output.path,
            ],
            token: token
        )
        
        if sourceDict["XMP-tiff:Orientation"] != nil {
            _ = try runToolProcess(["-overwrite_original", "-XMP-tiff:Orientation#=1", output.path], token: token)
        }
        
        guard try encodedImageHash(output, token: token) == targetDataHash else {
            throw FileveroError.failed("Metadata transfer changed encoded image data.")
        }
        
        let finalDict = try readMetadataDictionary(output, token: token)
        for key in ["IFD0:Orientation", "XMP-tiff:Orientation"] where finalDict[key] != nil {
            guard (finalDict[key] as? NSNumber)?.intValue == 1 else {
                throw FileveroError.failed(
                    "Metadata transfer did not preserve the image's display orientation. No output was saved."
                )
            }
        }
    }

    public static func edit(
        _ input: URL,
        changes: ImageMetadataOptions,
        options: OperationOptions,
        token: CancellationToken
    ) throws -> URL {
        try token.check()
        guard supportedImageFormats.contains(input.pathExtension.lowercased()) else {
            throw FileveroError.unsupported("Metadata-only editing is unavailable for this image format.")
        }
        
        let initialFingerprint = try computeFingerprint(input, token: token)
        let initialSourceHash = SHA256.hash(data: try Data(contentsOf: input))
        
        let scratchDirectory = try FileWorkspace.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        
        let stagedFile = scratchDirectory.appendingPathComponent("image").appendingPathExtension(input.pathExtension)
        try FileManager.default.copyItem(at: input.resolvingSymlinksInPath(), to: stagedFile)
        
        var cliArgs = ["-P", "-overwrite_original"]
        var hasContainerLevelEdits = changes.removeAll
        var xmpPendingUpdates: [String: String] = [:]
        var xmpPendingRemovals: [String] = []
        
        if changes.removeAll {
            cliArgs += ["-all=", "--ICC_Profile:all", "-TagsFromFile", "@", "-ColorSpaceTags", "-Orientation#"]
            if ["tif", "tiff"].contains(input.pathExtension.lowercased()) {
                cliArgs.append("-CommonIFD0=")
                let rawDict = try readMetadataDictionary(input, token: token)
                for prop in ["DocumentName", "HostComputer", "ImageID"] where rawDict["IFD0:" + prop] != nil {
                    cliArgs.append("-IFD0:\(prop)=")
                }
            }
        }
        
        for key in changes.removals.sorted() {
            guard isWritable(key) else {
                throw FileveroError.invalidInput("\(key) is structural or read-only metadata.")
            }
            if XMPMetadataEditor.isXMP(key) {
                xmpPendingRemovals.append(key)
                continue
            }
            hasContainerLevelEdits = true
            cliArgs.append("-\(try resolveTagName(key))=")
        }
        
        for (key, val) in changes.updates.sorted(by: { $0.key < $1.key }) {
            guard isWritable(key) else {
                throw FileveroError.invalidInput("\(key) is structural or read-only metadata.")
            }
            if XMPMetadataEditor.isXMP(key) {
                xmpPendingUpdates[key] = val
                continue
            }
            hasContainerLevelEdits = true
            let resolvedTag = try resolveTagName(key)
            if ["GPS:GPSLatitude", "GPS:GPSLongitude"].contains(resolvedTag), let coord = Double(val) {
                cliArgs.append("-\(resolvedTag)=\(abs(coord))")
                let ref = resolvedTag.hasSuffix("Latitude") ? (coord < 0 ? "S" : "N") : (coord < 0 ? "W" : "E")
                cliArgs.append("-\(resolvedTag)Ref=\(ref)")
            } else {
                cliArgs.append("-\(resolvedTag)=\(val)")
            }
        }
        
        if changes.removeLocation {
            hasContainerLevelEdits = true
            cliArgs += [
                "-gps:all=", "-XMP-exif:GPS*=", "-XMP-photoshop:City=", "-XMP-photoshop:State=",
                "-XMP-photoshop:Country=", "-XMP-iptcCore:Location=", "-XMP-iptcCore:CountryCode=",
                "-XMP-iptcExt:LocationCreated*=", "-XMP-iptcExt:LocationShown*=", "-IPTC:City=",
                "-IPTC:Province-State=", "-IPTC:Country-PrimaryLocation*=", "-IPTC:Sub-location=",
                "-IPTC:ContentLocation*=",
            ]
        }
        
        if hasContainerLevelEdits {
            cliArgs.append(stagedFile.path)
            _ = try runToolProcess(cliArgs, token: token)
        }
        
        if changes.removeLocation {
            // ExifTool cannot delete fields in undeclared custom XMP namespaces, so remove those from the packet.
            let packet = try runToolProcess(["-b", "-XMP", stagedFile.path], token: token).output
            xmpPendingRemovals += try XMPMetadataEditor.fields(packet).keys.filter(isLocationField)
        }

        if !xmpPendingUpdates.isEmpty || !xmpPendingRemovals.isEmpty {
            let originalXMP = try runToolProcess(["-b", "-XMP", stagedFile.path], token: token).output
            let modifiedXMP = try XMPMetadataEditor.edit(originalXMP, updates: xmpPendingUpdates, removals: xmpPendingRemovals)
            let tempXMPFile = scratchDirectory.appendingPathComponent("metadata.xmp")
            try modifiedXMP.write(to: tempXMPFile)
            _ = try runToolProcess(["-overwrite_original", "-XMP<=" + tempXMPFile.path, stagedFile.path], token: token)
        }
        
        let finalFingerprint = try computeFingerprint(stagedFile, token: token)
        guard initialFingerprint == finalFingerprint else {
            throw FileveroError.failed(
                "Metadata changes would alter encoded image data or its appearance. No output was saved."
            )
        }
        
        let writtenFields = try fields(stagedFile, token: token)
        for (key, val) in changes.updates {
            let expectedKey = formatDisplayKey(try resolveTagName(key))
            let actualVal = writtenFields.first(where: { $0.key.caseInsensitiveCompare(expectedKey) == .orderedSame })?.value
            let fullTag = try resolveTagName(key)
            let expectedVal = (["GPS:GPSLatitude", "GPS:GPSLongitude"].contains(fullTag) ? Double(val).map { String(abs($0)) } : nil) ?? val
            guard areEquivalentValues(actualVal, expectedVal) else {
                throw FileveroError.failed("The metadata field \(key) was not written. No output was saved.")
            }
        }
        
        for key in changes.removals {
            let expectedKey = formatDisplayKey(try resolveTagName(key))
            guard !writtenFields.keys.contains(where: { $0.caseInsensitiveCompare(expectedKey) == .orderedSame }) else {
                throw FileveroError.failed("The metadata field \(key) could not be removed.")
            }
        }
        
        if changes.removeLocation, let residual = writtenFields.keys.sorted().first(where: isLocationField) {
            throw FileveroError.failed("The location field \(residual) could not be removed. No output was saved.")
        }
        
        guard initialSourceHash == SHA256.hash(data: try Data(contentsOf: input)) else {
            throw FileveroError.failed("The source changed during this operation. No output was saved.")
        }
        
        try token.check()
        let finalOutput = FileWorkspace.unique(
            for: input,
            extension: input.pathExtension,
            suffix: changes.removeAll ? " - Clean" : changes.removeLocation ? " - No Location" : " - Metadata",
            directory: options.outputDirectory
        )
        try FileManager.default.moveItem(at: stagedFile, to: finalOutput)
        return finalOutput
    }

    public static func encodedImageHash(_ input: URL, token: CancellationToken = .init()) throws -> String {
        if input.pathExtension.lowercased() == "gif" {
            return try computeGifImageHash(Data(contentsOf: input))
        }
        let result = try runToolProcess(
            ["-j", "-s", "-api", "RequestAll=3", "-api", "ImageHashType=SHA256", "-ImageDataHash", input.path],
            token: token
        )
        let rows = try JSONSerialization.jsonObject(with: result.output) as? [[String: Any]]
        guard let hash = rows?.first?["ImageDataHash"] as? String, !hash.isEmpty else {
            throw FileveroError.failed("The encoded image data cannot be verified for this format.")
        }
        return hash
    }

    private static func computeGifImageHash(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, String(bytes: bytes[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true else {
            throw FileveroError.invalidInput("Invalid GIF header.")
        }
        
        var position = 13
        if bytes[10] & 0x80 != 0 {
            position += 3 * (1 << (Int(bytes[10] & 7) + 1))
        }
        guard position <= bytes.count else {
            throw FileveroError.invalidInput("Invalid GIF color table.")
        }
        
        var imageData = Data(bytes[0..<position])
        func skipBlocks(_ start: Int) throws -> Int {
            var curr = start
            while curr < bytes.count {
                let blockSize = Int(bytes[curr])
                curr += 1
                if blockSize == 0 { return curr }
                guard blockSize <= bytes.count - curr else { break }
                curr += blockSize
            }
            throw FileveroError.invalidInput("Truncated GIF block.")
        }
        
        while position < bytes.count {
            let start = position
            switch bytes[position] {
            case 0x2c:
                guard position + 10 <= bytes.count else { throw FileveroError.invalidInput("Truncated GIF frame.") }
                let packed = bytes[position + 9]
                position += 10
                if packed & 0x80 != 0 { position += 3 * (1 << (Int(packed & 7) + 1)) }
                guard position < bytes.count else { throw FileveroError.invalidInput("Truncated GIF image data.") }
                position = try skipBlocks(position + 1)
                imageData.append(contentsOf: bytes[start..<position])
            case 0x21:
                guard position + 2 < bytes.count else { throw FileveroError.invalidInput("Truncated GIF extension.") }
                let label = bytes[position + 1]
                position = try skipBlocks(position + 2)
                if label == 0xf9 || label == 0x01 {
                    imageData.append(contentsOf: bytes[start..<position])
                }
            case 0x3b:
                imageData.append(0x3b)
                return SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            default:
                throw FileveroError.invalidInput("Invalid GIF block type.")
            }
        }
        throw FileveroError.invalidInput("GIF trailer is missing.")
    }

    private struct ImageFingerprint: Equatable {
        var imageHash: String
        var profile: Data
        var frames: [[String]]
    }

    private static func computeFingerprint(_ input: URL, token: CancellationToken) throws -> ImageFingerprint {
        let hash = try encodedImageHash(input, token: token)
        let profile = try runToolProcess(["-b", "-ICC_Profile", input.path], token: token).output
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw FileveroError.invalidInput("Could not read image structure.")
        }
        var frames: [[String]] = []
        let globalProps = (CGImageSourceCopyProperties(source, nil) as? [String: Any]) ?? [:]
        let globalGIF = globalProps[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        
        for i in 0..<CGImageSourceGetCount(source) {
            let frameProps = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]) ?? [:]
            let gif = frameProps[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            frames.append([
                formatDisplayValue(frameProps[kCGImagePropertyPixelWidth as String] ?? 0),
                formatDisplayValue(frameProps[kCGImagePropertyPixelHeight as String] ?? 0),
                formatDisplayValue(frameProps[kCGImagePropertyOrientation as String] ?? 1),
                formatDisplayValue(gif?[kCGImagePropertyGIFDelayTime as String] ?? 0),
                formatDisplayValue(gif?[kCGImagePropertyGIFUnclampedDelayTime as String] ?? 0),
                formatDisplayValue(globalGIF?[kCGImagePropertyGIFLoopCount as String] ?? -1),
            ])
        }
        return ImageFingerprint(imageHash: hash, profile: profile, frames: frames)
    }

    private static func readMetadataDictionary(_ input: URL, token: CancellationToken) throws -> [String: Any] {
        let execution = try runToolProcess(["-j", "-G1", "-s", "-n", "-a", input.path], token: token)
        guard let list = try JSONSerialization.jsonObject(with: execution.output) as? [[String: Any]],
              let firstEntry = list.first
        else {
            throw FileveroError.failed("Could not inspect image metadata.")
        }
        return firstEntry
    }

    private static func runToolProcess(_ args: [String], token: CancellationToken) throws -> ProcessResult {
        var possibleLocations: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FILEVERO_EXIFTOOL"] {
            possibleLocations.append(URL(fileURLWithPath: env))
        }
        if let resource = Bundle.main.resourceURL {
            possibleLocations.append(resource.appendingPathComponent("Tools/ExifTool/exiftool"))
        }
        #if DEBUG
        let workspaceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        possibleLocations.append(workspaceRoot.appendingPathComponent("Tools/ExifTool/exiftool"))
        #endif
        
        guard let activeScript = possibleLocations.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FileveroError.missingDependency("ExifTool; run scripts/setup-exiftool.sh")
        }
        
        return try ExecutionPipeline.run(
            URL(fileURLWithPath: "/usr/bin/perl"),
            [activeScript.path, "-config", ""] + args,
            token: token
        )
    }

    private static func isLocationField(_ displayKey: String) -> Bool {
        let key = displayKey.lowercased()
        let name = key.components(separatedBy: "}.").last ?? key
        return key.contains("gps")
            || ["city", "state", "province-state", "country", "countrycode", "sub-location", "location"].contains(name)
            || ["country-primarylocation", "contentlocation", "locationcreated", "locationshown"].contains(where: name.hasPrefix)
    }

    private static func formatDisplayKey(_ tag: String) -> String {
        guard let colon = tag.firstIndex(of: ":") else { return tag }
        let group = String(tag[..<colon])
        var name = String(tag[tag.index(after: colon)...])
        if group == "IFD0", name == "ModifyDate" { name = "DateTime" }
        let mapped = ["IFD0": "TIFF", "IFD1": "IFD1", "ExifIFD": "Exif", "GPS": "GPS"][group] ?? group
        if group == "GPS", name.hasPrefix("GPS") { name = String(name.dropFirst(3)) }
        return "{\(mapped)}.\(name)"
    }

    private static func resolveTagName(_ key: String) throws -> String {
        let aliases: [String: String] = [
            "artist": "IFD0:Artist", "author": "IFD0:Artist", "copyright": "IFD0:Copyright",
            "description": "IFD0:ImageDescription", "title": "IFD0:ImageDescription", "comment": "ExifIFD:UserComment",
            "software": "IFD0:Software", "make": "IFD0:Make", "model": "IFD0:Model", "latitude": "GPS:GPSLatitude",
            "longitude": "GPS:GPSLongitude", "date": "ExifIFD:DateTimeOriginal",
        ]
        if let tag = aliases[key.lowercased()] { return tag }
        var tag = key
        if key.hasPrefix("{"), let close = key.range(of: "}.") {
            let group = String(key[key.index(after: key.startIndex)..<close.lowerBound])
            let name = String(key[close.upperBound...])
            let mapped = ["TIFF": "IFD0", "Exif": "ExifIFD", "GPS": "GPS"][group] ?? group
            let field = group == "TIFF" && name == "DateTime" ? "ModifyDate" : name
            tag = "\(mapped):\(group == "GPS" && !field.hasPrefix("GPS") ? "GPS" : "")\(field)"
        }
        guard tag.range(of: "^[A-Za-z0-9_][A-Za-z0-9_:-]*:[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
            throw FileveroError.invalidInput("Invalid metadata field: \(key)")
        }
        return tag
    }

    private static func formatDisplayValue(_ value: Any) -> String {
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: json, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func areEquivalentValues(_ actual: String?, _ expected: String) -> Bool {
        if actual == expected { return true }
        if let actual,
           let parsedA = try? JSONSerialization.jsonObject(with: Data(actual.utf8)),
           let parsedB = try? JSONSerialization.jsonObject(with: Data(expected.utf8)),
           let objA = parsedA as? NSObject,
           let objB = parsedB as? NSObject,
           objA == objB {
            return true
        }
        if let actual,
           let list = (try? JSONSerialization.jsonObject(with: Data(actual.utf8))) as? [String],
           list == [expected] {
            return true
        }
        if let actual, let doubleA = Double(actual), let doubleB = Double(expected) {
            return abs(doubleA - doubleB) < 0.0000001
        }
        return expected.isEmpty && actual == nil
    }
}

public typealias ImageMetadataEngine = ImageExifPipeline

