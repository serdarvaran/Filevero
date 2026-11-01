import AVKit
import AppKit
import FileveroCore
import PDFKit
import SwiftUI

/// Unified interactive workbench for image editing, cropping, annotation, redaction, and audio/video timeline editing.
public struct ToolWorkbench: View {
    @ObservedObject public var state: AppSessionController
    public let tool: ToolKind
    public let originalInputs: [URL]
    @State public var inputs: [URL]

    @MainActor
    public init(state: AppSessionController, tool: ToolKind) {
        self.state = state
        self.tool = tool
        self.originalInputs = state.inputs
        self._inputs = State(initialValue: state.inputs)
        if tool == .compress {
            let image = state.inputs.first.map { FileCategory.detect($0) == .image } ?? false
            let strength = image
                ? FormatPreferences.shared.imageCompressionStrength
                : FormatPreferences.shared.videoCompressionStrength
            self._preset = State(initialValue: strength == "strong" ? "Strong" : "Balanced")
            self._compressionSize = State(initialValue: image ? FormatPreferences.shared.imageCompressionSize : "original")
        }
    }

    @State public var options = OperationOptions()
    @State public var image: NSImage?
    @State public var baseImage: CGImage?
    @State public var showOriginal = false
    @State public var previewSize: CGSize?
    @State public var channelPreviewURL: URL?
    @State public var waveform: [Float] = []
    @State public var processedWaveform: [Float]?
    @State public var processedPlayback = false
    @State public var leftWaveform: [Float] = []
    @State public var rightWaveform: [Float] = []
    @State public var mediaPreviewFolder: URL?
    @State public var playbackURL: URL?
    @State public var previewBusy = false
    @State public var isLoading = true
    @State public var readyToApply = false
    @State public var loadRevision = UUID()
    @State public var editorGeneration = UUID()
    @State public var ownerWindowID: ObjectIdentifier?
    @State public var previewToken = CancellationToken()
    @State public var visualizationToken = CancellationToken()
    @State public var visualizationReady = false
    @State public var playingRange = false
    @State public var playerReachedEnd = false
    @State public var isPlaying = false
    @State public var seekRevision = UUID()
    @State public var seeking = false
    @State public var previewError: String?
    @State public var previewRenderError: String?
    @State public var imageSize = CGSize(width: 100, height: 100)
    @State public var duration = 0.0
    @State public var frameRate = 30.0
    @State public var playhead = 0.0
    @State public var player: AVPlayer?
    @State public var aspect = "Free"
    @State public var cropInteracting = false
    @State public var width = 0
    @State public var height = 0
    @State public var targetEnabled = false
    @State public var targetMode = "MB"
    @State public var targetValue = 1.0
    @State public var preset = "Balanced"
    @State public var compressionSize = "original"
    @State public var annotationKind: ImageAnnotationKind = .arrow
    @State public var selectingAnnotations = false
    @State public var annotationText = "Text"
    @State public var annotationColor = Color.red
    @State public var annotationStroke = 3.0
    @State public var annotationFont = 24.0
    @State public var annotationFontFamily = "system"
    @State public var previewZoom: CGFloat = 1
    @State public var lightingExpanded = true
    @State public var colorExpanded = false
    @State public var detailExpanded = false
    @State public var metadata: [String: String] = [:]
    @State public var originalMetadata: [String: String] = [:]
    @State public var metadataSearch = ""
    @State public var metadataRemoveAll = false
    @State public var addingMetadataField = false
    @State public var newMetadataKey = "{XMP-dc}.Title"
    @State public var newMetadataValue = ""
    @State public var selectedSplitClip: Int?
    @State public var processedDuration: Double?
    @State public var equalClips = 2
    @State public var qrResults: [String] = []
    @State public var pdfEditor = PDFPageEditorState()
    @State public var pdfAddedDocuments: [URL] = []
    @State public var passwordConfirmation = ""
    @Environment(\.dismiss) public var dismiss
    @Environment(\.fileveroTheme) public var theme

    public var input: URL? { inputs.first }
    public var category: FileCategory { input.map(FileCategory.detect) ?? .other }
    public var isGIFMetadata: Bool { input?.pathExtension.lowercased() == "gif" }
    public var usesImageMetadata: Bool { category == .image || isGIFMetadata }
    public var visual: Bool {
        [.editImage, .annotateImage, .cropImage, .frameImage, .redactImage, .createCollage, .removeBackground].contains(tool)
    }
    public var video: Bool {
        category == .video && ![.removeMetadata, .compress, .joinVideos].contains(tool)
            && !(tool == .videoSnapshots && inputs.count > 1)
    }
    public var audio: Bool { category == .audio && ![.removeMetadata, .compress, .joinAudio].contains(tool) }
    public var sideBySide: Bool { visual || video || audio }

    public var body: some View {
        let _ = theme
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                WindowCloseButton().frame(width: 26, height: 26)
                ZStack {
                    WindowDragRegion()
                    HStack(spacing: 13) {
                        Image(systemName: FeatureCatalog.toolSymbols[tool] ?? "slider.horizontal.3")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(ThemeTokenPalette.onAccentText)
                            .frame(width: 44, height: 44)
                            .background(ThemeTokenPalette.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            LText(tool.title).font(.system(size: 21, weight: .bold, design: .default)).tracking(-0.5)
                            LText(toolHint).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FileveroPill(
                            title: inputs.count > 1 ? "\(inputs.count) files" : input?.pathExtension.uppercased() ?? "FILE",
                            symbol: "doc"
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 17)
            .frame(height: 82)
            .uiAuditProbe("editor.header")

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(
                            sideBySide
                                ? L10n.text("Operation desk")
                                : "\(inputs.count > 1 ? "\(inputs.count) FILES" : input?.lastPathComponent ?? "")"
                        )
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                        if isLoading { ProgressView("Preparing your file…").font(.caption) }

                        controls
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fileveroCard(radius: 18)
                            .disabled(isLoading || !readyToApply)

                        if let previewError {
                            errorNotice(previewError) { self.previewError = nil }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: sideBySide ? .infinity : 720, alignment: .leading)
                }
                .frame(width: sideBySide ? 380 : nil)
                .frame(maxWidth: sideBySide ? nil : .infinity, maxHeight: .infinity)
                .uiAuditProbe("editor.options")

                if sideBySide {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Label("Preview", systemImage: "viewfinder")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ThemeTokenPalette.dynamicAccentText)
                                Spacer()
                                if visual {
                                    Text("\(Int(imageSize.width)) × \(Int(imageSize.height))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let previewRenderError {
                                errorNotice("The preview could not be updated: \(previewRenderError)") {
                                    self.previewRenderError = nil
                                }
                            }
                            if visual { imagePreview.disabled(isLoading || !readyToApply) }
                            if video || audio { mediaPreview.disabled(isLoading || !readyToApply) }
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                Text(input?.lastPathComponent ?? "").lineLimit(1)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                    .background(ThemeTokenPalette.surfaceFill)
                    .uiAuditProbe("editor.preview")

                    Divider()
                }
            }
            .uiAuditProbe("editor.body")

            if state.activeTool == tool, state.activeInputs == inputs,
               state.working || state.error != nil || (tool == .compress && !state.outputs.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    JobProgressView(state: state)
                    if tool == .compress, !state.working, !state.outputs.isEmpty {
                        LText(compressionResultText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(FileveroButtonStyle(.quiet))
                .uiAuditProbe("editor.reset")
                .accessibilityIdentifier("editor.reset")

                Spacer()

                Label("Original stays safe", systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button {
                    apply()
                } label: {
                    Label {
                        LText(primaryTitle)
                    } icon: {
                        Image(systemName: "arrow.up.right")
                    }
                    .uiAuditProbe("editor.primary.label")
                }
                .buttonStyle(FileveroButtonStyle(.primary))
                .uiAuditProbe("editor.primary")
                .accessibilityIdentifier("editor.primary")
                .disabled(!canApply)
                .help(isCropTool ? "Save a cropped copy (Return or ⌘S)" : "Save a fresh copy (⌘S)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .uiAuditProbe("editor.footer")
        }
        .frame(minWidth: sideBySide ? 900 : 480, minHeight: 420)
        .fileveroBackdrop()
        .tint(ThemeTokenPalette.primaryAccent)
        .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
        .textFieldStyle(.roundedBorder)
        .uiAuditStatus(
            isLoading
                ? "loading"
                : readyToApply ? "ready" : "failed: " + (previewError ?? "Input did not become ready")
        )
        .fileveroAnimation(value: state.working)
        .task(id: loadRevision) { await load() }
        .task(id: previewKey) { await renderPreview() }
        .task(id: visualizationKey) { await renderVisualization() }
        .onChange(of: previewKey) { _ in if processedPlayback { playOriginal(play: false) } }
        .background(WindowIdentityReader { ownerWindowID = $0 })
        .background(
            WorkbenchKeyboardShortcuts(
                enabled: !isLoading && readyToApply && !state.working,
                onCommand: handleShortcut
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, ownerWindowID == ObjectIdentifier(window) {
                disposeMedia()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main)
        ) { notification in
            if let item = notification.object as? AVPlayerItem, item === player?.currentItem {
                playerReachedEnd = true
            }
        }
        .onChange(of: width) {
            if $0 > 0, tool == .editImage { options.width = $0 }
        }
        .onChange(of: height) {
            if $0 > 0, tool == .editImage { options.height = $0 }
        }
        .onChange(of: options.splitPoints) { _ in
            options.discardedClips = []
            selectedSplitClip = nil
        }
        .onDeleteCommand { discardSelectedClip() }
        .onDisappear { disposeMedia() }
    }

    func errorNotice(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack {
            LText(message).font(.callout).foregroundStyle(.orange)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss preview error")
        }
    }

    public var toolHint: String { tool.editorHint ?? "Adjust your settings and save a copy." }

    public var primaryTitle: String {
        switch tool {
        case .redactAudio: return options.audioMode == "bleep" ? "Save bleeped copy" : "Save muted copy"
        case .videoSnapshots where inputs.count > 1: return "Save \(inputs.count) frames"
        case .videoSnapshots:
            return options.snapshotTimes.count == 1 ? "Save 1 frame" : "Save \(options.snapshotTimes.count) frames"
        case .splitVideo: return options.joinSplitClips ? "Export one video" : "Export clips"
        case .recognizeText: return options.ocrOutput == "txt" ? "Save text" : "Save searchable PDF"
        case .createAnimation: return (options.animation?.format ?? "gif") == "mp4" ? "Create video" : "Create GIF"
        default: return tool.saveTitle ?? FeatureCatalog.toolNames[tool] ?? tool.title
        }
    }

    public var canApply: Bool {
        guard !state.working, !isLoading, readyToApply, input != nil else { return false }
        switch tool {
        case .cropImage, .cropVideo:
            guard !cropInteracting, let crop = options.crop else { return false }
            return crop.x >= 0 && crop.y >= 0 && crop.width >= 1 && crop.height >= 1
                && crop.x + crop.width <= imageSize.width && crop.y + crop.height <= imageSize.height
        case .removeMetadata where isGIFMetadata: return metadataRemoveAll
        case .splitVideo:
            return (!options.splitPoints.isEmpty || options.equalClips != nil)
                && options.discardedClips.count < splitIntervals.count
        case .videoSnapshots: return inputs.count > 1 || !options.snapshotTimes.isEmpty
        case .watermark, .protectPDF, .unlockPDF:
            return BatchOperationControls.isReady(tool, options: options, confirmation: passwordConfirmation)
        case .annotateImage: return !options.imageAnnotations.isEmpty
        case .redactImage, .redactVideo: return !options.redactions.isEmpty
        case .redactAudio: return !options.audioRedactions.isEmpty
        default: return true
        }
    }

    public func load() async {
        guard let input else { return }
        let generation = editorGeneration
        let token = previewToken
        isLoading = true
        readyToApply = false
        defer { if generation == editorGeneration, !token.isCancelled { isLoading = false } }
        do {
            try checkGeneration(generation, token: token)
            if category == .image {
                let cgImage = try await ExecutionPipeline.offload { try ImageEngine.load(input) }
                try checkGeneration(generation, token: token)
                baseImage = cgImage
                image = NSImage(cgImage: cgImage, size: .zero)
                imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                width = cgImage.width
                height = cgImage.height
                if tool == .compress { setCompressionDimensions(compressionSize) }
            }
            if category == .audio || category == .video {
                let info = try await MediaEngine.inspectAsync(input, token: token)
                try checkGeneration(generation, token: token)
                duration = info.duration
                options.end = duration
                if let videoStream = info.video {
                    imageSize = CGSize(width: videoStream.width ?? 100, height: videoStream.height ?? 100)
                    width = videoStream.width ?? 100
                    height = videoStream.height ?? 100
                    frameRate = max(1, videoStream.frameRate ?? 30)
                }
                if category == .video {
                    let firstFrame = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
                        generator.appliesPreferredTrackTransform = true
                        return try? generator.copyCGImage(at: .zero, actualTime: nil)
                    }.value
                    try checkGeneration(generation, token: token)
                    if let firstFrame {
                        image = NSImage(cgImage: firstFrame, size: .zero)
                    }
                }
                if audio || video {
                    let prepared = try await withTaskCancellationHandler(
                        operation: { try await MediaPreviewEngine.prepare(input, token: token) },
                        onCancel: { token.cancel() }
                    )
                    guard generation == editorGeneration, !token.isCancelled, !Task.isCancelled else {
                        prepared.removeTemporaryFiles()
                        return
                    }
                    player?.pause()
                    if let old = mediaPreviewFolder { try? FileManager.default.removeItem(at: old) }
                    mediaPreviewFolder = prepared.ownedTemporaryDirectory
                    playbackURL = prepared.playbackURL
                    playerReachedEnd = false
                    player = AVPlayer(url: prepared.playbackURL)

                    if category == .audio, tool != .audioToVideo {
                        let peaks = try await MediaPreviewEngine.waveformPeaksAsync(input, token: token)
                        try checkGeneration(generation, token: token)
                        waveform = peaks

                        if tool == .audioChannels {
                            let left = try await MediaPreviewEngine.waveformPeaksAsync(
                                input, channel: 0, token: token)
                            try checkGeneration(generation, token: token)
                            leftWaveform = left
                            let right = (info.audio?.channels ?? 1) > 1
                                ? try await MediaPreviewEngine.waveformPeaksAsync(input, channel: 1, token: token)
                                : left
                            try checkGeneration(generation, token: token)
                            rightWaveform = right
                        }
                    }
                }
            }
            if tool == .removeMetadata {
                let loaded: [String: String]
                if usesImageMetadata {
                    loaded = try await ExecutionPipeline.offload { try ImageEngine.readMetadata(input, token: token) }
                } else if category == .pdf {
                    loaded = try await Task.detached {
                        let pdf = try PDFEngine.open(input)
                        var values: [String: String] = [:]
                        for (key, value) in pdf.documentAttributes ?? [:] {
                            values[String(describing: key)] = String(describing: value)
                        }
                        return values
                    }.value
                } else {
                    loaded = try await MediaEngine.readMetadataAsync(input, token: token)
                }
                try checkGeneration(generation, token: token)
                metadata = loaded
                originalMetadata = loaded
            }
            if tool == .organizePDF {
                let document = try await Task.detached { try PDFEngine.open(input) }.value
                try checkGeneration(generation, token: token)
                pdfEditor.reset(document: document)
            }
            if tool == .frameImage { options.imageFrame = .init() }
            if tool == .createCollage { options.collage = .init() }
            if tool == .audioToVideo {
                width = 1920
                height = 1080
                options.backgroundColor = "#000000"
            }
            if tool == .redactVideo || tool == .redactImage {
                options.backgroundColor = "#000000"
                options.redactionMode = "black"
            }
            try checkGeneration(generation, token: token)
            readyToApply = true
        } catch {
            if generation == editorGeneration, !token.isCancelled, !Task.isCancelled {
                previewError = error.localizedDescription
            }
        }
    }

    public func reset() {
        disposeMedia()
        previewToken = CancellationToken()
        visualizationToken = CancellationToken()
        isLoading = true
        readyToApply = false
        inputs = originalInputs
        options = OperationOptions()
        pdfEditor.reset()
        pdfAddedDocuments = []
        passwordConfirmation = ""
        selectedSplitClip = nil
        aspect = "Free"
        cropInteracting = false
        equalClips = 2
        width = 0
        height = 0
        image = nil
        baseImage = nil
        imageSize = CGSize(width: 100, height: 100)
        previewSize = nil
        previewZoom = 1
        showOriginal = false
        duration = 0
        frameRate = 30
        playhead = 0
        playerReachedEnd = false
        playingRange = false
        processedPlayback = false
        processedDuration = nil
        waveform = []
        leftWaveform = []
        rightWaveform = []
        processedWaveform = nil
        playbackURL = nil
        visualizationReady = false
        previewBusy = false
        previewError = nil
        previewRenderError = nil
        metadata = [:]
        originalMetadata = [:]
        metadataSearch = ""
        metadataRemoveAll = false
        addingMetadataField = false
        newMetadataKey = "{XMP-dc}.Title"
        newMetadataValue = ""
        qrResults = []
        annotationKind = .arrow
        selectingAnnotations = false
        annotationText = "Text"
        annotationColor = .red
        annotationStroke = 3
        annotationFont = 24
        annotationFontFamily = "system"
        targetEnabled = false
        targetMode = "MB"
        targetValue = 1
        preset = "Balanced"
        compressionSize = "original"
        if tool == .compress {
            let image = category == .image
            preset = (image
                ? FormatPreferences.shared.imageCompressionStrength
                : FormatPreferences.shared.videoCompressionStrength) == "strong" ? "Strong" : "Balanced"
            compressionSize = image ? FormatPreferences.shared.imageCompressionSize : "original"
        }
        loadRevision = UUID()
    }

    public func checkGeneration(_ generation: UUID, token: CancellationToken) throws {
        try Task.checkCancellation()
        try token.check()
        if generation != editorGeneration { throw CancellationError() }
    }

    public func apply(joinedSplit: Bool = false) {
        guard canApply else { return }
        if tool == .organizePDF {
            saveOrganizedPDF()
            return
        }
        var applied = options
        if tool == .splitVideo { applied.joinSplitClips = joinedSplit }
        if tool == .videoSnapshots, inputs.count > 1 { applied.snapshotFraction = options.snapshotFraction ?? 0.1 }
        if width > 0 { applied.width = width }
        if height > 0 { applied.height = height }
        if [.cropImage, .cropVideo].contains(tool), var crop = applied.crop {
            crop.width = Double(width)
            crop.height = Double(height)
            applied.crop = crop
        }
        if tool == .cropImage {
            applied.width = nil
            applied.height = nil
        }
        if tool == .compress {
            applied.quality = preset == "Balanced" ? 0.8 : 0.45
            if targetEnabled {
                guard targetValue.isFinite, targetValue > 0 else {
                    previewError = "Enter a positive, finite target size."
                    return
                }
                if targetMode == "percent" {
                    guard targetValue < 100 else {
                        previewError = "Enter a reduction greater than 0% and less than 100%."
                        return
                    }
                    applied.percentage = targetValue
                } else {
                    let bytes = targetValue * (targetMode == "MB" ? 1_000_000 : 1_000)
                    guard bytes.isFinite, bytes >= 1, bytes < Double(Int64.max) else {
                        previewError = "Enter a target of at least one byte and less than \(Int64.max) bytes."
                        return
                    }
                    applied.targetBytes = Int64(bytes)
                }
            }
        }
        if tool == .redactImage {
            var redact = options.imageRedaction ?? ImageRedactionOptions()
            redact.style = options.redactionMode == "black" ? .solid : options.redactionMode == "pixelate" ? .pixelate : .blur
            redact.color = options.backgroundColor
            applied.imageRedaction = redact
        }
        if tool == .removeMetadata {
            applied.metadata = metadata
            if !usesImageMetadata && (category == .audio || category == .video) {
                for key in originalMetadata.keys where metadata[key] == nil { applied.metadata[key] = "" }
            }
            applied.metadataRemoveAll = metadataRemoveAll
            if usesImageMetadata {
                var edit = ImageMetadataOptions()
                edit.removeAll = metadataRemoveAll
                edit.updates = metadata.filter { originalMetadata[$0.key] != $0.value }
                edit.removals = metadataRemoveAll ? [] : originalMetadata.keys.filter { metadata[$0] == nil }
                applied.imageMetadata = edit
            }
        }
        state.execute(.tool(tool), options: applied, inputs: inputs)
    }

    public func saveOrganizedPDF() {
        guard canApply, !pdfEditor.pages.isEmpty else { return }
        savePDFPages(Array(pdfEditor.pages.indices), selectionOnly: false)
    }

    public func saveSelectedPDFPages() {
        guard canApply, pdfEditor.hasSelection else { return }
        savePDFPages(Array(pdfEditor.selection), selectionOnly: true)
    }

    private func savePDFPages(_ positions: [Int], selectionOnly: Bool) {
        var settings = options
        settings.pdfPageOrder = positions.map { pdfEditor.sourceIndexes[$0] }
        settings.pdfPageDocuments = positions.map { pdfEditor.documentIndexes[$0] }
        settings.pdfAdditionalDocuments = pdfAddedDocuments
        settings.pdfPageRotations = Dictionary(
            uniqueKeysWithValues: positions.enumerated().map { ($0.offset, pdfEditor.pages[$0.element].rotation) })
        settings.pdfSavesSelection = selectionOnly
        state.execute(.tool(.organizePDF), options: settings, inputs: inputs)
    }

    /// Image pages are written as PDFs the queued save still needs after the editor closes, so they are kept for a
    /// day and removed the next time pages are added.
    private static func addedPageFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Filevero Added Pages", isDirectory: true)
        let stale = Date().addingTimeInterval(-86_400)
        for folder in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < stale {
            try? FileManager.default.removeItem(at: folder)
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Adds the pages of chosen PDFs and images after the selection; images become one page each.
    public func addPDFPages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls {
                var source = url
                switch FileCategory.detect(url) {
                case .pdf: break
                case .image:
                    var conversion = OperationOptions()
                    conversion.outputDirectory = try Self.addedPageFolder()
                    source = try PDFEngine.create(inputs: [url], options: conversion, token: .init())[0]
                default:
                    throw FileveroError.unsupported("Choose PDFs or still images to add as pages.")
                }
                pdfEditor.insert(try PDFEngine.open(source), as: pdfAddedDocuments.count + 1)
                pdfAddedDocuments.append(source)
            }
        } catch {
            previewError = error.localizedDescription
        }
    }

    public func detectRedactions(faces: Bool) {
        guard let input, readyToApply, !isLoading else { return }
        let generation = editorGeneration
        let token = previewToken
        Task {
            do {
                let regions = try await ExecutionPipeline.offload {
                    try ImageEngine.recognizedRegions(input, faces: faces, text: !faces)
                }
                try checkGeneration(generation, token: token)
                options.redactions += regions.map(\.rect)
            } catch {
                if generation == editorGeneration, !token.isCancelled { previewError = error.localizedDescription }
            }
        }
    }

    public var previewKey: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = (try? encoder.encode(options)) ?? Data()
        data.append(contentsOf: inputs.map(\.path).joined(separator: "\0").utf8)
        return data
    }

    public func renderPreview() async {
        guard let baseImage, visual, tool != .cropImage else { return }
        let generation = editorGeneration
        let token = previewToken
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            try Task.checkCancellation()
            var updated = options
            if tool == .redactImage {
                var r = updated.imageRedaction ?? .init()
                r.style = updated.redactionMode == "black" ? .solid : updated.redactionMode == "pixelate" ? .pixelate : .blur
                r.color = updated.backgroundColor
                updated.imageRedaction = r
            }
            let kind = tool
            let sources = inputs
            let cgImage = try await ExecutionPipeline.offload { [updated] in
                if kind == .createCollage {
                    return try ImageEngine.collageImage(
                        sources.map { try ImageEngine.load($0) }, settings: updated.collage ?? .init()
                    )
                }
                return try ImageEngine.preview(baseImage, tool: kind, options: updated)
            }
            try checkGeneration(generation, token: token)
            image = NSImage(cgImage: cgImage, size: .zero)
            previewSize = CGSize(width: cgImage.width, height: cgImage.height)
            previewRenderError = nil
        } catch is CancellationError {
            // Superseded by a newer edit or a reset.
        } catch {
            if generation == editorGeneration, !token.isCancelled, !Task.isCancelled {
                previewRenderError = error.localizedDescription
            }
        }
    }

    public var annotationStyle: ImageAnnotation {
        var a = ImageAnnotation(kind: annotationKind, rect: .init(x: 0, y: 0, width: 0, height: 0))
        a.text = annotationText
        a.color = hex(annotationColor)
        a.number = options.imageAnnotations.count + 1
        a.strokeWidth = annotationStroke
        a.fontSize = annotationFont
        a.fontFamily = annotationFontFamily
        return a
    }

    public func addAnnotation(_ rect: EditRect, _ points: [ImagePoint]) {
        guard var a = AnnotationDrawing.draft(style: annotationStyle, points: points) else { return }
        if annotationKind == .image {
            let panel = NSOpenPanel()
            guard panel.runModal() == .OK else { return }
            a.imageURL = panel.url
        }
        options.imageAnnotations.append(a)
    }

    public func setCrop(_ rect: EditRect) {
        var r = rect
        r.x = r.x.rounded(.down)
        r.y = r.y.rounded(.down)
        r.width = r.width.rounded(.down)
        r.height = r.height.rounded(.down)
        options.crop = r
        width = Int(r.width)
        height = Int(r.height)
    }
}

// Backward-compatibility alias
public typealias ToolEditor = ToolWorkbench

