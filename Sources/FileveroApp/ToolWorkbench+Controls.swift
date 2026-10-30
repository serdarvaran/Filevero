import AppKit
import FileveroCore
import PDFKit
import SwiftUI

// MARK: - ToolWorkbench Controls Layout & Tool Dispatch

extension ToolWorkbench {
    @ViewBuilder var controls: some View {
        switch tool {
        case .compress: compressionControls
        case .cropImage, .cropVideo: cropControls
        case .editImage: imageControls
        case .annotateImage: annotationControls
        case .frameImage: frameControls
        case .removeBackground: removeBackgroundControls
        case .createCollage: collageControls
        case .redactImage, .redactVideo: redactionControls
        case .trimVideo, .trimAudio: trimControls
        case .changeVideoSpeed:
            slider("Playback speed", value: $options.speed, range: 0.25...4, unit: "×")
            HStack {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { speed in
                    Button("\(speed, specifier: "%.2g")×") {
                        options.speed = speed
                        player?.currentItem?.audioTimePitchAlgorithm = .spectral
                        if playerReachedEnd { seek(0) }
                        player?.rate = Float(speed)
                    }.buttonStyle(.bordered)
                }
            }
            Text("Audio pitch is preserved.").font(.caption).foregroundStyle(.secondary)
        case .normalizeAudio:
            slider("Target loudness", value: $options.targetLoudness, range: -40 ... -5, unit: "LUFS")
            slider("Loudness range", value: $options.loudnessRange, range: 1...20, unit: "LU")
            slider("True peak limit", value: $options.truePeak, range: -9 ... -0.1, unit: "dBTP")
        case .audioChannels:
            Picker("Output", selection: $options.channels) {
                Text("Mono").tag(1)
                Text("Stereo").tag(2)
            }.pickerStyle(.segmented)
            slider("Left volume", value: $options.leftVolume, range: 0...2, unit: "×")
            slider("Right volume", value: $options.rightVolume, range: 0...2, unit: "×")
            HStack {
                Button("Preview Left") { previewChannel(0) }
                Button("Preview Right") { previewChannel(1) }
                Button("Original") { playOriginal() }
            }
        case .splitVideo:
            HStack {
                Text(options.splitPoints.count == 1 ? "1 split point" : "\(options.splitPoints.count) split points")
                Spacer()
                Button("Add Split", action: addSplitPoint).disabled(!canAddSplitPoint).help("Add split at playhead (M)")
            }
            ForEach(Array(options.splitPoints.enumerated()), id: \.offset) { index, time in
                HStack {
                    Text(timeLabel(time))
                    Spacer()
                    Button {
                        options.equalClips = nil
                        options.splitPoints.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }
            HStack {
                Stepper("Equal clips: \(equalClips)", value: $equalClips, in: 2...100)
                Button("Set") {
                    options.equalClips = equalClips
                    options.splitPoints = (1..<equalClips).map { duration * Double($0) / Double(equalClips) }
                }
            }
            splitEditingControls
        case .videoSnapshots where inputs.count > 1: batchControls
        case .videoSnapshots:
            HStack {
                Text("\(options.snapshotTimes.count) selected")
                Spacer()
                Button("Add Frame") { options.snapshotTimes.append(playhead) }.help("Add frame at playhead (M)")
            }
            if let source = playbackURL ?? input {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) {
                    ForEach(Array(options.snapshotTimes.enumerated()), id: \.offset) { index, time in
                        VStack {
                            VideoFrameThumbnail(source: source, time: time).frame(height: 70).cornerRadius(6)
                            HStack {
                                Text(timeLabel(time)).font(.caption)
                                Spacer()
                                Button {
                                    options.snapshotTimes.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                            }
                        }
                    }
                }
            }
        case .audioToVideo:
            Picker("Style", selection: $options.visualizationStyle) {
                Text("Waveform").tag("waveform")
                Text("Spectrum").tag("spectrum")
                Text("Bars").tag("bars")
                Text("Still image").tag("image")
            }
            if options.visualizationStyle == "image" {
                Button("Choose Still Image…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK { options.visualizationImage = panel.url }
                }
            }
            HStack {
                Text("Video size")
                Spacer()
                Button("Landscape") {
                    width = 1920
                    height = 1080
                }
                Button("Portrait") {
                    width = 1080
                    height = 1920
                }
                Button("Square") {
                    width = 1080
                    height = 1080
                }
            }
            dimensionFields
            if options.visualizationStyle == "image" {
                ColorPicker("Background", selection: colorBinding($options.backgroundColor))
            }
        case .redactAudio:
            Picker("Style", selection: $options.audioMode) {
                Text("Bleep").tag("bleep")
                Text("Mute").tag("mute")
            }.pickerStyle(.segmented)
            timeRangeFields
            Button("Add Redaction") {
                options.audioRedactions.append(TimeRange(start: options.start, end: options.end ?? duration))
            }
            ForEach(Array(options.audioRedactions.enumerated()), id: \.offset) { index, range in
                HStack {
                    Text("\(timeLabel(range.start)) → \(timeLabel(range.end))")
                    Spacer()
                    Button {
                        options.audioRedactions.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }
        case .joinVideos, .mergePDF, .joinAudio, .combineToPDF: orderControls
        case .createAnimation:
            VStack(alignment: .leading, spacing: 18) {
                batchControls
                orderControls
            }
        case .watermark, .uniformSize, .pageNumbers, .protectPDF, .unlockPDF: batchControls
        case .organizePDF: pdfControls
        case .removeMetadata: metadataControls
        case .recognizeText:
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Language",
                    selection: Binding(
                        get: { options.ocrLanguages.joined(separator: ",") },
                        set: { options.ocrLanguages = $0.split(separator: ",").map(String.init) })
                ) {
                    if TextRecognitionEngine.turkishAvailable {
                        Text("Turkish and English").tag("tr-TR,en-US")
                        Text("Turkish").tag("tr-TR")
                    }
                    Text("English").tag("en-US")
                }.onAppear { if !TextRecognitionEngine.turkishAvailable { options.ocrLanguages = ["en-US"] } }
                Picker("Output", selection: $options.ocrOutput) {
                    Text("Searchable PDF").tag("pdf")
                    Text("Text file").tag("txt")
                }.pickerStyle(.segmented)
                Text(
                    options.ocrOutput == "pdf"
                        ? "Pages keep their appearance. Only pages without selectable text get a text layer."
                        : "The recognized text is saved as a plain text file."
                ).font(.caption).foregroundStyle(.secondary)
                Text("Text is recognized on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            }
        case .splitPDF:
            Stepper("Pages per file: \(options.pagesPerFile)", value: $options.pagesPerFile, in: 1...1000)
            TextField("Page ranges, for example 1-3, 5", text: $options.pageRanges)
        default: EmptyView()
        }
    }

    var removeBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LText("Automatically isolates the main subject using on-device Apple Vision machine learning and removes the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    LText("AI Subject Isolation")
                        .font(.headline)
                    LText("Preserves fine contours and transparent alpha layers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Divider()

            LText("Backdrop Preview")
                .font(.headline)
            Picker("Backdrop", selection: $options.backgroundColor) {
                Text("Transparent").tag("#00000000")
                Text("White").tag("#FFFFFF")
                Text("Black").tag("#000000")
                Text("Gray").tag("#808080")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LText("Output is automatically exported as a high-fidelity PNG preserving full transparency.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var compressionControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let input, let size = try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                LText("Original size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                    .fontWeight(.semibold)
            }
            Text("Compression preset").font(.headline)
            Picker("Preset", selection: $preset) {
                Text("Balanced").tag("Balanced")
                Text("Strong").tag("Strong")
            }.pickerStyle(.segmented).labelsHidden()
            Text(
                preset == "Balanced"
                    ? "Smaller files with less quality loss." : "Smaller files with stronger compression."
            ).foregroundStyle(.secondary).font(.callout)
            if category == .image {
                Picker("Image size", selection: $compressionSize) {
                    Text("Keep original dimensions").tag("original")
                    Text("75%").tag("75")
                    Text("50%").tag("50")
                    Text("25%").tag("25")
                    Text("Custom dimensions").tag("custom")
                    Text("Large · 2560 px longest edge").tag("large")
                    Text("Medium · 1920 px longest edge").tag("medium")
                    Text("Small · 1280 px longest edge").tag("small")
                }.onChange(of: compressionSize) { value in
                    setCompressionDimensions(value)
                }
                if compressionSize == "custom" { dimensionFields }
            }
            Divider()
            Toggle("Compress to target file size", isOn: $targetEnabled)
            if targetEnabled {
                HStack {
                    TextField("Target", value: $targetValue, format: .number)
                    Picker("Unit", selection: $targetMode) {
                        Text("MB").tag("MB")
                        Text("KB").tag("KB")
                        Text("% reduction").tag("percent")
                    }.frame(width: 150)
                }
            }
        }
    }

    var trimControls: some View {
        VStack(spacing: 14) {
            timeRangeFields
            if tool == .trimAudio {
                Toggle("Remove silence from beginning and end", isOn: $options.trimSilence)
                if options.trimSilence {
                    slider("Silence threshold", value: $options.silenceThresholdDb, range: -80 ... -10, unit: "dB")
                }
            }
            LText("Selected duration: \(timeLabel(max(0, (options.end ?? duration) - options.start)))").font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var timeRangeFields: some View {
        HStack {
            Text("Start")
            TextField("Seconds", value: $options.start, format: .number.precision(.fractionLength(3)))
            Text("End")
            TextField(
                "Seconds", value: Binding(get: { options.end ?? duration }, set: { options.end = $0 }),
                format: .number.precision(.fractionLength(3)))
        }.textFieldStyle(.roundedBorder)
    }

    var splitIntervals: [TimeRange] {
        let points = [0] + options.splitPoints.filter { $0 > 0 && $0 < duration }.sorted() + [duration]
        return zip(points, points.dropFirst()).map { TimeRange(start: $0.0, end: $0.1) }
    }

    var splitEditingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a clip and press Delete to remove it from the result.").font(.caption).foregroundStyle(
                .secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(splitIntervals.enumerated()), id: \.offset) { index, range in
                        Button {
                            selectedSplitClip = index
                            if processedPlayback { playOriginal(play: false) }
                            seek(range.start)
                        } label: {
                            VStack(spacing: 4) {
                                LText("Clip \(index+1)").font(.caption.bold())
                                Text(timeLabel(range.end - range.start)).font(.caption2.monospacedDigit())
                            }.frame(width: max(65, 300 * (range.end - range.start) / max(0.001, duration)), height: 46)
                                .strikethrough(options.discardedClips.contains(index)).foregroundStyle(
                                    options.discardedClips.contains(index) ? Color.secondary : Color.primary
                                ).background(
                                    selectedSplitClip == index
                                        ? FileveroPalette.accent.opacity(0.3) : Color.primary.opacity(0.08)
                                ).cornerRadius(6)
                        }.buttonStyle(.plain).opacity(options.discardedClips.contains(index) ? 0.4 : 1)
                    }
                }.focusable()
            }
            HStack {
                Button("Delete Clip") { discardSelectedClip() }.disabled(
                    selectedSplitClip == nil || splitIntervals.count - options.discardedClips.count <= 1)
                Button("Restore Clips") { options.discardedClips = [] }.disabled(options.discardedClips.isEmpty)
                Spacer()
            }
            HStack {
                Button(previewBusy ? "Preparing…" : "Play Result") { processedPreview() }.disabled(
                    previewBusy || !canApply)
                Button("Export One Video") { apply(joinedSplit: true) }.disabled(!canApply)
            }
        }
    }

    func discardSelectedClip() {
        guard tool == .splitVideo, let selectedSplitClip, splitIntervals.indices.contains(selectedSplitClip),
            !options.discardedClips.contains(selectedSplitClip), splitIntervals.count - options.discardedClips.count > 1
        else { return }
        options.discardedClips.append(selectedSplitClip)
    }

    func setCompressionDimensions(_ value: String) {
        guard value != "custom" else { return }
        let maximum = ["large": 2560.0, "medium": 1920.0, "small": 1280.0][value]
        let factor: Double
        if let maximum {
            factor = min(1, maximum / Double(max(imageSize.width, imageSize.height)))
        } else {
            factor = value == "original" ? 1 : (Double(value) ?? 100) / 100
        }
        width = max(1, Int(imageSize.width * factor))
        height = max(1, Int(imageSize.height * factor))
    }

    var batchControls: some View {
        BatchOperationControls(
            tool: tool, includesPDF: inputs.contains { FileCategory.detect($0) == .pdf }, options: $options,
            confirmation: $passwordConfirmation, color: { colorBinding($0) })
    }

    var orderControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback / document order").font(.headline)
            ForEach(Array(inputs.enumerated()), id: \.offset) { index, url in
                HStack {
                    Text("\(index+1)").foregroundStyle(.secondary).frame(width: 20)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button {
                        inputs.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }.disabled(index == 0)
                    Button {
                        inputs.swapAt(index, index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }.disabled(index == inputs.count - 1)
                }
            }
        }
    }

    var pdfControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 14) {
                ForEach(Array(pdfEditor.pages.enumerated()), id: \.offset) { index, page in
                    VStack {
                        PDFPageThumbnail(page: page)
                        Text("\(index+1)").font(.caption)
                    }.padding(8).background(
                        pdfEditor.selectedPage == index
                            ? FileveroPalette.accent.opacity(0.2) : Color.primary.opacity(0.03)
                    ).cornerRadius(8).onTapGesture { pdfEditor.select(index) }
                }
            }
            HStack {
                Button("Rotate") { pdfEditor.rotateSelected() }.disabled(!pdfEditor.hasSelection)
                Button("Duplicate") { pdfEditor.duplicateSelected() }.disabled(!pdfEditor.hasSelection)
                Button("Delete") { pdfEditor.deleteSelected() }.disabled(!pdfEditor.canDelete)
                Button("Move Left") { pdfEditor.moveSelected(by: -1) }.disabled(!pdfEditor.canMoveLeft)
                Button("Move Right") { pdfEditor.moveSelected(by: 1) }.disabled(!pdfEditor.canMoveRight)
            }
            Toggle("Make all pages the same width", isOn: $options.pdfUniformWidth)
        }
    }

    var metadataControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search metadata", text: $metadataSearch)
            ForEach(metadataGroups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    LText(group).font(.headline).foregroundStyle(.secondary)
                    ForEach(visibleMetadata.filter { metadataGroup($0) == group }, id: \.self) { key in
                        HStack(alignment: .top) {
                            Text(key).font(.caption).frame(width: 130, alignment: .leading).textSelection(.enabled)
                            if isGIFMetadata || (usesImageMetadata && !ImageMetadataEngine.isWritable(key)) {
                                Text(metadata[key] ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(
                                    .enabled)
                            } else {
                                TextField(
                                    "Value", text: Binding(get: { metadata[key] ?? "" }, set: { metadata[key] = $0 })
                                ).textFieldStyle(.roundedBorder)
                                Button {
                                    metadata.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Remove All") {
                    metadata = [:]
                    metadataRemoveAll = true
                }
                Spacer()
                if !isGIFMetadata {
                    Button("Add Field") {
                        newMetadataKey =
                            category == .image ? "{XMP-dc}.Title" : category == .pdf ? "Title" : "file:title"
                        newMetadataValue = ""
                        addingMetadataField = true
                    }.popover(isPresented: $addingMetadataField) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add Metadata Field").font(.headline)
                            TextField("Field", text: $newMetadataKey)
                            TextField("Value", text: $newMetadataValue)
                            Button("Add") {
                                metadata[newMetadataKey] = newMetadataValue
                                addingMetadataField = false
                            }.disabled(
                                newMetadataKey.isEmpty
                                    || (usesImageMetadata && !ImageMetadataEngine.isWritable(newMetadataKey)))
                        }.padding(18).frame(width: 300)
                    }
                }
            }
            if isGIFMetadata {
                Text("Frame timing and repeat count are preserved.").font(.caption).foregroundStyle(.secondary)
            }
            if category == .image {
                Text("Encoded pixels, color profile and display orientation are preserved.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if category == .image {
                Button("Read QR Codes") { readQRCodes() }
                ForEach(qrResults, id: \.self) { Text($0).textSelection(.enabled) }
            }
        }
    }

    var visibleMetadata: [String] {
        metadata.keys.sorted().filter {
            metadataSearch.isEmpty || $0.localizedCaseInsensitiveContains(metadataSearch)
                || (metadata[$0] ?? "").localizedCaseInsensitiveContains(metadataSearch)
        }
    }

    var metadataGroups: [String] { Array(Set(visibleMetadata.map(metadataGroup))).sorted() }

    func metadataGroup(_ key: String) -> String {
        if let separator = key.firstIndex(of: category == .image ? "." : ":") { return String(key[..<separator]) }
        return category == .pdf ? "Document" : "File"
    }

    func readQRCodes() {
        guard let input else { return }
        let generation = editorGeneration
        let token = previewToken
        Task {
            let codes = (try? await ExecutionPipeline.offload { try ImageEngine.qrCodes(input) }) ?? []
            guard generation == editorGeneration, !token.isCancelled else { return }
            qrResults = codes
        }
    }
}

/// Renders a page thumbnail off the main actor; large documents would otherwise re-render every page
/// on the main thread each time the grid updates.
private struct PDFPageThumbnail: View {
    let page: PDFPage
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.primary.opacity(0.03)
            }
        }
        .frame(height: 140)
        .task(id: ObjectIdentifier(page)) {
            // The copy is owned by the render task alone, so it never races the editor's own page objects.
            guard let copy = page.copy() as? PDFPage else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                FileArtworkImage(copy.thumbnail(of: NSSize(width: 100, height: 140), for: .mediaBox))
            }.value
            if !Task.isCancelled { image = rendered.image }
        }
    }
}

