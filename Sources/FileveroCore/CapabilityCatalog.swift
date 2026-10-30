import Foundation

/// Central registry of supported conversion routes, tool associations, format matrix, and category mappings.
public enum CapabilityCatalog {
    public static let conversionMatrix: [String: [String]] = [
        "jpg": ["png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "png": ["jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "webp": ["jpg", "png", "heic", "tiff", "avif", "bmp", "pdf"],
        "heic": ["jpg", "png", "webp", "tiff", "avif", "bmp", "pdf"],
        "tiff": ["jpg", "png", "webp", "heic", "avif", "bmp", "pdf"],
        "svg": ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "avif": ["jpg", "png", "webp", "heic", "tiff", "bmp", "pdf"],
        "bmp": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "mp3": ["m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        "m4a": ["mp3", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        "aac": ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        "wav": ["mp3", "m4a", "flac", "ogg", "opus", "aiff", "wma"],
        "flac": ["mp3", "m4a", "wav", "ogg", "opus", "aiff", "wma"],
        "ogg": ["mp3", "m4a", "wav", "flac", "opus", "aiff", "wma"],
        "opus": ["mp3", "m4a", "wav", "flac", "ogg", "aiff", "wma"],
        "aiff": ["mp3", "m4a", "wav", "flac", "ogg", "opus", "wma"],
        "wma": ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"],
        "mp4": ["mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        "m4v": ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        "mov": ["mp4", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        "mkv": ["mp4", "mov", "webm", "avi", "wmv", "gif", "mp3"],
        "webm": ["mp4", "mov", "mkv", "avi", "wmv", "gif", "mp3"],
        "avi": ["mp4", "mov", "mkv", "webm", "wmv", "gif", "mp3"],
        "wmv": ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3"],
        "gif": ["mp4", "mov", "mkv", "webm", "avi", "wmv"],
        "pdf": ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"],
        "ppt": ["pdf", "jpg", "png"],
        "pptx": ["pdf", "jpg", "png"],
        "docx": ["pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "pages": ["docx", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "md": ["docx", "pages", "pdf", "txt", "html", "epub", "png", "jpg"],
        "rtf": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "rtfd": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "textclipping": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "epub": ["pdf", "docx", "pages", "txt", "md", "html"],
        "txt": ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png"],
        "xlsx": ["ods", "csv", "tsv", "pdf"],
        "xls": ["xlsx", "ods", "csv", "tsv", "pdf"],
        "ods": ["xlsx", "csv", "tsv", "pdf"],
        "csv": ["xlsx", "ods", "tsv", "pdf"],
        "tsv": ["xlsx", "ods", "csv", "pdf"],
        "srt": ["vtt", "txt"],
        "vtt": ["srt", "txt"],
        "zip": ["tar", "gz", "bz2"],
        "tar": ["zip", "gz", "bz2"],
        "gz": ["zip", "tar", "bz2"],
        "bz2": ["zip", "tar", "gz"],
        "xz": ["zip", "tar", "gz", "bz2"],
        "7z": ["zip", "tar", "gz", "bz2"],
        "rar": ["zip", "tar", "gz", "bz2"],
    ]

    public static let macOnlyConversionMatrix: [String: [String]] = [
        "doc": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "odt": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "html": ["docx", "pages", "pdf", "txt", "md", "epub", "png", "jpg"],
        // Windows has no built-in 7z or xz writer.
        "zip": ["xz", "7z"],
        "tar": ["xz", "7z"],
        "gz": ["xz", "7z"],
        "bz2": ["xz", "7z"],
        "xz": ["7z"],
        "7z": ["xz"],
        "rar": ["xz", "7z"],
        // Camera RAW decoding relies on ImageIO; Windows has no RAW decoder.
        "dng": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "cr2": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "cr3": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "nef": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "arw": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "rw2": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "orf": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
    ]

    public static var allConversions: [String: [String]] {
        conversionMatrix.merging(macOnlyConversionMatrix) { shared, macOnly in shared + macOnly }
    }

    public static let toolSymbols: [ToolKind: String] = [
        .compress: "arrow.down.right.and.arrow.up.left",
        .removeMetadata: "tag",
        .editImage: "slider.horizontal.3",
        .annotateImage: "pencil.and.outline",
        .frameImage: "photo.artframe",
        .cropImage: "crop",
        .normalizeAudio: "waveform",
        .muteVideo: "speaker.slash.fill",
        .trimVideo: "scissors",
        .splitPDF: "rectangle.split.2x1",
        .organizePDF: "square.grid.2x2",
        .extractArchive: "archivebox",
        .createPDF: "doc.badge.plus",
        .mergePDF: "doc.on.doc",
        .cropVideo: "crop",
        .changeVideoSpeed: "speedometer",
        .joinVideos: "film.stack",
        .videoSnapshots: "camera",
        .splitVideo: "film",
        .audioToVideo: "waveform",
        .trimAudio: "scissors",
        .audioChannels: "hifispeaker.2",
        .createCollage: "rectangle.3.group",
        .redactImage: "eye.slash",
        .redactVideo: "eye.slash",
        .redactAudio: "waveform.badge.minus",
        .readQRCode: "qrcode.viewfinder",
        .recognizeText: "text.viewfinder",
        .renameFiles: "character.cursor.ibeam",
        .organizeFiles: "folder.badge.gearshape",
        .findDuplicates: "square.on.square.dashed",
        .createArchive: "archivebox",
        .watermark: "seal",
        .uniformSize: "aspectratio",
        .createAnimation: "play.rectangle.on.rectangle",
        .removeLocation: "location.slash",
        .pageNumbers: "number",
        .protectPDF: "lock.doc",
        .unlockPDF: "lock.open",
        .combineToPDF: "doc.on.doc",
        .joinAudio: "waveform.path",
        .removeBackground: "wand.and.stars",
    ]

    public static let toolNames: [ToolKind: String] = [
        .compress: "Compress",
        .removeMetadata: "Metadata",
        .editImage: "Edit Photo",
        .annotateImage: "Annotate Photo",
        .frameImage: "Add BG",
        .cropImage: "Crop Image",
        .normalizeAudio: "Normalize Volume",
        .muteVideo: "Remove Audio",
        .trimVideo: "Trim Video",
        .splitPDF: "Split PDF",
        .organizePDF: "Organize PDF",
        .extractArchive: "Extract Archive",
        .createPDF: "Create PDF",
        .mergePDF: "Merge PDFs",
        .cropVideo: "Crop Video",
        .changeVideoSpeed: "Change Video Speed",
        .joinVideos: "Join Videos",
        .videoSnapshots: "Video Snapshots",
        .splitVideo: "Split Video",
        .audioToVideo: "Audio Visualizer",
        .trimAudio: "Trim Audio",
        .audioChannels: "Convert Audio Channels",
        .createCollage: "Create Collage",
        .redactImage: "Redact Photo",
        .redactVideo: "Redact Video",
        .redactAudio: "Bleep Audio",
        .readQRCode: "Read QR Codes",
        .removeBackground: "Remove Background",
    ]

    public static let singleTools: [String: [ToolKind]] = [
        "jpg": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "png": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "webp": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "heic": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "tiff": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "svg": [],
        "avif": [.removeBackground],
        "bmp": [.removeBackground],
        "mp3": [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio],
        "m4a": [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio],
        "wav": [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio],
        "flac": [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio],
        "ogg": [],
        "opus": [],
        "aiff": [],
        "wma": [],
        "mp4": [
            .compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots,
            .splitVideo, .redactVideo,
        ],
        "mov": [
            .compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots,
            .splitVideo, .redactVideo,
        ],
        "mkv": [
            .compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots,
            .splitVideo, .redactVideo,
        ],
        "webm": [],
        "avi": [],
        "wmv": [],
        "gif": [.removeMetadata],
        "pdf": [.compress, .removeMetadata, .splitPDF, .organizePDF],
        "ppt": [],
        "pptx": [],
        "docx": [],
        "pages": [],
        "md": [],
        "rtf": [],
        "rtfd": [],
        "textclipping": [],
        "epub": [],
        "txt": [],
        "xlsx": [],
        "xls": [],
        "ods": [],
        "csv": [],
        "tsv": [],
        "srt": [],
        "vtt": [],
        "zip": [.extractArchive],
        "tar": [.extractArchive],
        "gz": [.extractArchive],
        "bz2": [.extractArchive],
        "xz": [.extractArchive],
        "7z": [.extractArchive],
        "rar": [.extractArchive],
    ]

    public static let multipleTools: [String: [ToolKind]] = [
        "jpg": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "png": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "webp": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "heic": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "tiff": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "svg": [.createPDF, .createCollage],
        "avif": [],
        "bmp": [],
        "mp3": [.compress, .removeMetadata, .normalizeAudio],
        "m4a": [.compress, .removeMetadata, .normalizeAudio],
        "wav": [.compress, .removeMetadata, .normalizeAudio],
        "flac": [.compress, .removeMetadata, .normalizeAudio],
        "ogg": [],
        "opus": [],
        "aiff": [],
        "wma": [],
        "mp4": [.compress, .removeMetadata, .muteVideo, .joinVideos],
        "mov": [.compress, .removeMetadata, .muteVideo, .joinVideos],
        "mkv": [.compress, .removeMetadata, .muteVideo, .joinVideos],
        "webm": [],
        "avi": [],
        "wmv": [],
        "gif": [.removeMetadata],
        "pdf": [.compress, .removeMetadata, .splitPDF, .mergePDF],
        "ppt": [],
        "pptx": [],
        "docx": [],
        "pages": [],
        "md": [],
        "rtf": [],
        "rtfd": [],
        "textclipping": [],
        "epub": [],
        "txt": [],
        "xlsx": [],
        "xls": [],
        "ods": [],
        "csv": [],
        "tsv": [],
        "srt": [],
        "vtt": [],
        "zip": [.extractArchive],
        "tar": [.extractArchive],
        "gz": [.extractArchive],
        "bz2": [.extractArchive],
        "xz": [.extractArchive],
        "7z": [.extractArchive],
        "rar": [.extractArchive],
    ]

    /// Camera RAW decoding (ImageIO) has no Windows engine.
    public static let macOnlySingleTools: [String: [ToolKind]] = [
        "dng": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "cr2": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "cr3": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "nef": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "arw": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "rw2": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
        "orf": [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .removeBackground],
    ]

    public static let macOnlyMultipleTools: [String: [ToolKind]] = [
        "dng": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "cr2": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "cr3": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "nef": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "arw": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "rw2": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
        "orf": [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage],
    ]

    public static let extensionAliases: [String: String] = [
        "jpeg": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff", "markdown": "md", "htm": "html", "gzip": "gz",
        "tgz": "gz", "tbz2": "bz2", "tbz": "bz2", "txz": "xz",
    ]

    public static func normalizedExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return extensionAliases[ext] ?? ext
    }

    public static func formats(for inputs: [URL]) -> [String] {
        guard let first = inputs.first else { return [] }
        guard inputs.allSatisfy({ !isOrdinaryFolder($0) }) else { return [] }
        let conversions = allConversions
        return (conversions[normalizedExtension(first)] ?? []).filter { format in
            inputs.allSatisfy { (conversions[normalizedExtension($0)] ?? []).contains(format) }
        }
    }

    public static func tools(for inputs: [URL]) -> [ToolKind] {
        guard let first = inputs.first else { return [] }
        guard inputs.allSatisfy({ !isOrdinaryFolder($0) }) else { return [] }
        let dictionary = (inputs.count > 1 ? multipleTools : singleTools)
            .merging(inputs.count > 1 ? macOnlyMultipleTools : macOnlySingleTools) { shared, macOnly in shared + macOnly }
        var tools = (dictionary[normalizedExtension(first)] ?? []).filter { tool in
            inputs.allSatisfy { (dictionary[normalizedExtension($0)] ?? []).contains(tool) }
        }
        if inputs.allSatisfy(BarcodeScannerEngine.supports) { tools.append(.readQRCode) }
        if inputs.allSatisfy(VisionTextRecognizer.supports) { tools.append(.recognizeText) }
        return tools + macOnlyTools(for: inputs)
    }

    private static func macOnlyTools(for inputs: [URL]) -> [ToolKind] {
        let categories = Set(inputs.map(FileCategory.detect))
        let several = inputs.count > 1
        var tools: [ToolKind] = []
        if categories.isSubset(of: [.image, .pdf]) { tools.append(.watermark) }
        if categories == [.image] {
            tools.append(.uniformSize)
            if inputs.allSatisfy({ locationFormats.contains(normalizedExtension($0)) }) {
                tools.append(.removeLocation)
            }
            if several { tools.append(.createAnimation) }
        }
        if categories == [.pdf] { tools += [.pageNumbers, .protectPDF, .unlockPDF] }
        if several, categories != [.pdf], categories != [.image], inputs.allSatisfy(PDFBatchProcessor.canCombine) {
            tools.append(.combineToPDF)
        }
        if several, categories == [.audio] { tools.append(.joinAudio) }
        if several, categories == [.video], !tools.contains(.videoSnapshots) { tools.append(.videoSnapshots) }
        return tools
    }

    private static let locationFormats: Set<String> = [
        "jpg", "png", "heic", "tiff", "webp", "avif", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"
    ]

    public static func organizingTools(for inputs: [URL]) -> [ToolKind] {
        guard !inputs.isEmpty else { return [] }
        let hasFolder = inputs.contains(where: isOrdinaryFolder)
        var tools: [ToolKind] = [.renameFiles]
        if !hasFolder { tools.append(.organizeFiles) }
        if inputs.count > 1 || hasFolder { tools.append(.findDuplicates) }
        tools.append(.createArchive)
        return tools
    }

    private static func isOrdinaryFolder(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            && !["rtfd", "pages"].contains(normalizedExtension(url))
    }
}

// MARK: - Compatibility Bridge
public typealias FeatureCatalog = CapabilityCatalog

