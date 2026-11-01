import Foundation

/// Primary classification of supported file formats.
public enum FileCategory: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, document, presentation, spreadsheet, ebook, subtitle, archive, other
    
    public var title: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .presentation: return "Slides"
        case .spreadsheet: return "Spreadsheets"
        case .ebook: return "EPUB"
        case .subtitle: return "Subtitles"
        case .archive: return "Archives"
        case .other: return "Files"
        }
    }
    
    /// Ordered registry of recognized file extensions for automatic categorization.
    public static let knownExtensions: [(category: FileCategory, extensions: [String])] = [
        (.image, ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "avif", "bmp", "svg", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"]),
        (.video, ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "gif"]),
        (.audio, ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "aac"]),
        (.pdf, ["pdf"]),
        (.document, ["doc", "docx", "pages", "md", "markdown", "txt", "rtf", "rtfd", "textclipping", "html", "htm", "odt"]),
        (.presentation, ["ppt", "pptx", "key"]),
        (.spreadsheet, ["xlsx", "xls", "ods", "csv", "tsv", "numbers"]),
        (.ebook, ["epub"]),
        (.subtitle, ["srt", "vtt"]),
        (.archive, ["zip", "tar", "gz", "gzip", "tgz", "bz2", "tbz2", "tbz", "xz", "txz", "7z", "rar"]),
    ]
    
    public static func detect(_ url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()
        return knownExtensions.first { $0.extensions.contains(ext) }?.category ?? .other
    }
}

/// Catalog of editing, transformation, and utility tools supported by Filevero.
public enum ToolKind: String, Codable, CaseIterable, Sendable {
    case compress, removeMetadata, editImage, annotateImage, frameImage, cropImage
    case normalizeAudio, muteVideo, trimVideo, splitPDF, organizePDF, extractArchive
    case createPDF, mergePDF, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots
    case splitVideo, audioToVideo, trimAudio, audioChannels, createCollage
    case redactImage, redactVideo, redactAudio, readQRCode, recognizeText
    case renameFiles, organizeFiles, findDuplicates, createArchive
    case watermark, uniformSize, createAnimation, removeLocation
    case pageNumbers, protectPDF, unlockPDF, combineToPDF, joinAudio
    case removeBackground, prepareToShare

    /// Explanatory hint displayed beneath the tool title in the editor panel.
    public var editorHint: String? {
        switch self {
        case .removeBackground: return "Isolate the subject and remove the background with AI."
        case .cropImage, .cropVideo: return "Select the area you want to keep."
        case .editImage: return "Adjust color, light and detail."
        case .annotateImage: return "Add shapes, text and annotations."
        case .frameImage: return "Add a background and adjust the frame."
        case .compress: return "Reduce file size with the settings you choose."
        case .removeMetadata: return "Review and remove file metadata."
        case .createCollage: return "Combine images into a collage."
        case .recognizeText: return "Make scans and photos searchable."
        case .watermark: return "Add text or a logo to every file."
        case .uniformSize: return "Give every image the same size."
        case .createAnimation: return "Turn images into a GIF or a video."
        case .pageNumbers: return "Number the pages of every PDF."
        case .protectPDF: return "Require a password to open the PDF."
        case .unlockPDF: return "Save a copy that opens without a password."
        case .combineToPDF: return "Join documents, images and PDFs into one PDF."
        case .joinAudio: return "Join audio files into one track."
        case .trimAudio, .trimVideo: return "Choose the part you want to keep."
        default: return nil
        }
    }

    /// Primary confirmation action button label.
    public var saveTitle: String? {
        switch self {
        case .editImage: return "Save edited copy"
        case .removeBackground: return "Save transparent copy"
        case .annotateImage: return "Save annotated copy"
        case .frameImage: return "Save with background"
        case .redactImage, .redactVideo: return "Save redacted copy"
        case .audioToVideo: return "Create visualization"
        case .removeMetadata: return "Save metadata copy"
        case .cropImage, .cropVideo: return "Save cropped copy"
        case .trimAudio, .trimVideo: return "Save trimmed copy"
        case .changeVideoSpeed: return "Save speed copy"
        case .audioChannels: return "Save audio copy"
        case .organizePDF: return "Save organized PDF"
        case .compress: return "Compress & save"
        case .watermark: return "Save watermarked copies"
        case .uniformSize: return "Save resized copies"
        case .pageNumbers: return "Save numbered copies"
        case .protectPDF: return "Save protected copy"
        case .unlockPDF: return "Save unlocked copy"
        case .combineToPDF: return "Create PDF"
        case .joinAudio: return "Join audio"
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .compress: return "Compress"
        case .removeMetadata: return "Remove Metadata"
        case .editImage: return "Edit Image"
        case .annotateImage: return "Annotate"
        case .frameImage: return "Frame Image"
        case .cropImage: return "Crop Image"
        case .normalizeAudio: return "Normalize Audio"
        case .muteVideo: return "Mute Video"
        case .trimVideo: return "Trim Video"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize PDF"
        case .extractArchive: return "Extract Archive"
        case .createPDF: return "Create PDF"
        case .mergePDF: return "Merge PDFs"
        case .cropVideo: return "Crop Video"
        case .changeVideoSpeed: return "Change Speed"
        case .joinVideos: return "Join Videos"
        case .videoSnapshots: return "Video Snapshots"
        case .splitVideo: return "Split Video"
        case .audioToVideo: return "Audio to Video"
        case .trimAudio: return "Trim Audio"
        case .audioChannels: return "Audio Channels"
        case .createCollage: return "Create Collage"
        case .redactImage: return "Redact Image"
        case .redactVideo: return "Redact Video"
        case .redactAudio: return "Redact Audio"
        case .readQRCode: return "Read QR Codes"
        case .recognizeText: return "Recognize Text"
        case .renameFiles: return "Rename Files"
        case .organizeFiles: return "Sort into Folders"
        case .findDuplicates: return "Find Duplicates"
        case .createArchive: return "Create Archive"
        case .watermark: return "Add Watermark"
        case .uniformSize: return "Same Size"
        case .createAnimation: return "Create GIF or Video"
        case .removeLocation: return "Remove Location"
        case .pageNumbers: return "Add Page Numbers"
        case .protectPDF: return "Add Password"
        case .unlockPDF: return "Remove Password"
        case .combineToPDF: return "Combine into PDF"
        case .joinAudio: return "Join Audio"
        case .removeBackground: return "Remove Background"
        case .prepareToShare: return "Prepare to Share"
        }
    }
}

/// Comprehensive parameter container for all image, media, PDF, and archive operations.
public struct OperationOptions: Codable, Sendable {
    public var quality: Double = 0.8
    public var audioBitrate: Int = 256
    public var audioSampleDepth: String = "matchSource"
    public var videoMaxHeight: Int = 0
    public var videoEncoder: String? = nil
    public var videoBitrateKbps: Int? = nil
    public var gifFrameRate: Int = 15
    public var gifMaxWidth: Int = 960
    public var preserveMetadata: Bool = true
    public var compressionPreset: String = "balanced"
    /// Format for Create Archive; nil keeps ZIP and older saved jobs decodable.
    public var archiveFormat: String? = nil
    public var targetBytes: Int64? = nil
    /// Percentage reduction: 20 means at most 80% of the original bytes.
    public var percentage: Double? = nil
    public var width: Int? = nil
    public var height: Int? = nil
    public var crop: EditRect? = nil
    public var rotation: Int = 0
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var flipHorizontal: Bool = false
    public var start: Double = 0
    public var end: Double? = nil
    public var speed: Double = 1
    public var channels: Int = 2
    public var targetLoudness: Double = -16
    public var loudnessRange: Double = 11
    public var truePeak: Double = -1.5
    public var leftVolume: Double = 1
    public var rightVolume: Double = 1
    public var splitPoints: [Double] = []
    public var equalClips: Int? = nil
    public var discardedClips: [Int] = []
    public var joinSplitClips: Bool = false
    public var audioRedactions: [TimeRange] = []
    public var trimSilence: Bool = false
    public var silenceThresholdDb: Double = -50
    public var visualizationStyle: String = "waveform"
    public var visualizationImage: URL? = nil
    public var videoRedactions: [VideoRedaction] = []
    public var splitInterval: Double = 30
    public var snapshotTimes: [Double] = [0]
    public var pageRanges: String = ""
    public var pagesPerFile: Int = 1
    public var pdfPageOrder: [Int] = []
    public var pdfPageRotations: [Int: Int] = [:]
    public var pdfUniformWidth: Bool = false
    /// Document of each `pdfPageOrder` entry: 0 is the input, n is `pdfAdditionalDocuments[n - 1]`. Empty means all from the input.
    public var pdfPageDocuments: [Int] = []
    public var pdfAdditionalDocuments: [URL] = []
    public var pdfSavesSelection: Bool = false
    public var epubLayout: String = "reflowable"
    public var pdfOfficeLayout: String = "editable"
    public var dpi: Int = 300
    public var password: String = ""
    public var metadata: [String: String] = [:]
    public var metadataRemoveAll: Bool = false
    public var annotations: [Annotation] = []
    public var imageAdjustments: ImageAdjustments = .init()
    public var imageFrame: ImageFrameOptions? = nil
    public var collage: CollageOptions? = nil
    public var imageAnnotations: [ImageAnnotation] = []
    public var imageRedaction: ImageRedactionOptions? = nil
    public var imageMetadata: ImageMetadataOptions? = nil
    public var redactions: [EditRect] = []
    public var redactionMode: String = "blur"
    public var backgroundColor: String = "#FFFFFF"
    public var padding: Int = 32
    public var cornerRadius: Int = 16
    public var collageColumns: Int = 2
    public var audioMode: String = "bleep"
    public var outputDirectory: URL? = nil
    public var outputNameTemplate: String? = nil
    public var outputSequence: OutputSequence? = nil
    public var ocrLanguages: [String] = TextRecognitionEngine.defaultLanguages
    public var ocrOutput: String = "pdf"
    public var maxImageDimension: Int? = nil
    public var watermark: WatermarkOptions? = nil
    public var uniformSize: UniformSizeOptions? = nil
    public var animation: AnimationOptions? = nil
    public var pageNumbers: PageNumberOptions? = nil
    public var snapshotFraction: Double? = nil
    public var revealInFinder: Bool = true
    
    public init() {}
}

/// Discrete transform target: either converting to a target format or applying a tool.
public enum Operation: Sendable {
    case convert(String)
    case tool(ToolKind)
    
    public var title: String {
        switch self {
        case .convert(let format):
            return "Convert to \(format.uppercased())"
        case .tool(let tool):
            return tool.title
        }
    }
}

/// Request descriptor for an operation execution.
public struct ConversionRequest: Sendable {
    public var inputs: [URL]
    public var operation: Operation
    public var options: OperationOptions
    
    public init(inputs: [URL], operation: Operation, options: OperationOptions = .init()) {
        self.inputs = inputs
        self.operation = operation
        self.options = options
    }
}

