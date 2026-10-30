import AppKit
import FileveroCore
import SwiftUI

// MARK: - ToolWorkbench Image & Visual Controls

extension ToolWorkbench {
    var cropControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag across the preview to select the area to keep.").font(.caption).foregroundStyle(.secondary)
            Text("Shift locks the ratio · Return crops\nDrag inside to move; drag a handle to resize.").font(.caption)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tool == .cropImage, inputs.count > 1 {
                Text("This crop applies to every selected image and must fit inside each one.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Aspect ratio", selection: $aspect) {
                ForEach(["Free", "1:1", "16:9", "9:16", "4:3", "3:4"], id: \.self) { LText($0) }
            }.pickerStyle(.segmented).onChange(of: aspect) { value in
                guard value != "Free" else { return }
                let a = value.split(separator: ":").compactMap { Double($0) }
                if a.count == 2 {
                    let ratio = a[0] / a[1]
                    let w = min(imageSize.width, imageSize.height * ratio)
                    let h = w / ratio
                    setCrop(EditRect(x: (imageSize.width - w) / 2, y: (imageSize.height - h) / 2, width: w, height: h))
                }
            }
            Menu {
                ForEach(SocialMediaPreset.standardPresets) { preset in
                    Button(preset.label) {
                        applyPreset(preset)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.2.square.on.square")
                    Text("Social & Web Presets…")
                }
            }
            .menuStyle(.borderlessButton)
            HStack {
                number("W", value: cropDimension(width: true))
                number("H", value: cropDimension(width: false))
                Text("px").foregroundStyle(.secondary)
            }
            if let crop = options.crop {
                HStack {
                    number("X", value: Binding(get: { Int(crop.x) }, set: { options.crop?.x = Double($0) }))
                    number("Y", value: Binding(get: { Int(crop.y) }, set: { options.crop?.y = Double($0) }))
                }
            }
            HStack {
                Button("Select All") {
                    setCrop(EditRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
                    aspect = "Free"
                }
                Button("Clear Selection") {
                    options.crop = nil
                    width = Int(imageSize.width)
                    height = Int(imageSize.height)
                }.disabled(options.crop == nil)
            }
        }
    }

    var isCropTool: Bool { tool == .cropImage || tool == .cropVideo }

    var cropAspectRatio: CGFloat? {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] / parts[1] : nil
    }

    func cropDimension(width isWidth: Bool) -> Binding<Int> {
        Binding(
            get: { isWidth ? width : height },
            set: { value in
                var rect = options.crop ?? EditRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
                if isWidth {
                    rect.width = Double(value)
                    if let ratio = cropAspectRatio { rect.height = rect.width / ratio }
                } else {
                    rect.height = Double(value)
                    if let ratio = cropAspectRatio { rect.width = rect.height * ratio }
                }
                setCrop(rect)
            })
    }

    func cropInteraction(_ active: Bool) {
        cropInteracting = active
        if active, let window = NSApp.keyWindow, ownerWindowID == ObjectIdentifier(window) {
            window.makeFirstResponder(nil)
        }
    }

    func applyPreset(_ preset: SocialMediaPreset) {
        let rect = preset.fit(in: imageSize)
        setCrop(rect)
        aspect = preset.ratioText
        width = preset.width
        height = preset.height
    }

    var dimensionFields: some View {
        HStack {
            number("W", value: $width)
            number("H", value: $height)
            Text("px").foregroundStyle(.secondary)
        }
    }

    var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Show Original", isOn: $showOriginal).toggleStyle(.button)
                Spacer()
                Button("−") { previewZoom = max(0.25, previewZoom / 1.25) }
                Text("\(Int(previewZoom * 100))%").font(.caption.monospacedDigit())
                Button("+") { previewZoom = min(4, previewZoom * 1.25) }
                Button("Fit") { previewZoom = 1 }
            }
            HStack {
                Button("Rotate Left") {
                    options.rotation -= 90
                    swap(&width, &height)
                }
                Button("Rotate Right") {
                    options.rotation += 90
                    swap(&width, &height)
                }
                Toggle("Flip", isOn: $options.flipHorizontal)
            }
            dimensionFields
            DisclosureGroup("Lighting", isExpanded: $lightingExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Exposure", value: $options.imageAdjustments.exposure, range: -3...3, unit: "EV")
                    slider("Brightness", value: $options.imageAdjustments.brightness, range: -1...1)
                    slider("Contrast", value: relative($options.imageAdjustments.contrast), range: -1...1)
                    slider("Highlights", value: $options.imageAdjustments.highlights, range: -1...1)
                    slider("Shadows", value: $options.imageAdjustments.shadows, range: -1...1)
                    slider("Whites", value: $options.imageAdjustments.whites, range: -1...1)
                    slider("Blacks", value: $options.imageAdjustments.blacks, range: -1...1)
                    slider("Gamma", value: relative($options.imageAdjustments.gamma), range: -0.8...2)
                }.padding(.top, 12)
            }
            DisclosureGroup("Color", isExpanded: $colorExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Temperature", value: $options.imageAdjustments.temperature, range: -1...1)
                    slider("Tint", value: $options.imageAdjustments.tint, range: -1...1)
                    slider("Saturation", value: relative($options.imageAdjustments.saturation), range: -1...1)
                    slider("Vibrance", value: $options.imageAdjustments.vibrance, range: -1...1)
                    slider("Hue", value: $options.imageAdjustments.hue, range: -180...180, unit: "°")
                }.padding(.top, 12)
            }
            DisclosureGroup("Detail", isExpanded: $detailExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Clarity", value: $options.imageAdjustments.clarity, range: 0...1)
                    slider("Texture", value: $options.imageAdjustments.texture, range: -1...1)
                    slider("Sharpen", value: $options.imageAdjustments.sharpen, range: 0...2)
                    slider("Dehaze", value: $options.imageAdjustments.dehaze, range: 0...1)
                    slider("Grain", value: $options.imageAdjustments.grain, range: 0...1)
                    slider("Noise reduction", value: $options.imageAdjustments.noiseReduction, range: 0...1)
                    slider("Vignette", value: $options.imageAdjustments.vignette, range: 0...2)
                    slider("Fade", value: $options.imageAdjustments.fade, range: 0...1)
                    slider("Blur", value: $options.imageAdjustments.blur, range: 0...30, unit: "px")
                }.padding(.top, 12)
            }
        }
    }

    var annotationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tool", selection: $annotationKind) {
                ForEach(ImageAnnotationKind.allCases, id: \.self) { LText($0.rawValue.capitalized).tag($0) }
            }.onChange(of: annotationKind) { _ in selectingAnnotations = false }
            Toggle(isOn: $selectingAnnotations) { Label("Select / Move", systemImage: "cursorarrow") }
                .toggleStyle(.button)
            TextField("Text or callout", text: $annotationText)
            ColorPicker("Color", selection: $annotationColor)
            Picker("Font", selection: $annotationFontFamily) {
                Text("System").tag("system")
                Text("Rounded").tag("rounded")
                Text("Serif").tag("serif")
                Text("Monospaced").tag("monospaced")
            }
            slider("Stroke width", value: $annotationStroke, range: 1...40, unit: "px")
            slider("Text size", value: $annotationFont, range: 8...160, unit: "px")
            LText(
                selectingAnnotations
                    ? "Drag an existing annotation to move it; drag its handles to resize. Turn off Select / Move to draw."
                    : "Drag to draw with the selected tool. Use Select / Move to edit an existing annotation."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Undo") { if !options.imageAnnotations.isEmpty { options.imageAnnotations.removeLast() } }
                Button("Clear") { options.imageAnnotations = [] }
            }
            ForEach(Array(options.imageAnnotations.enumerated()), id: \.offset) { index, a in
                HStack {
                    Text("\(index+1). \(a.kind.rawValue.capitalized)")
                    Spacer()
                    Button("Delete") { options.imageAnnotations.remove(at: index) }
                }
            }
        }
    }

    var frameControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Background", selection: frame(\.backdrop)) {
                ForEach(ImageBackdrop.allCases, id: \.self) { LText($0.rawValue.capitalized).tag($0) }
            }
            if options.imageFrame?.backdrop == .gradient {
                HStack {
                    ForEach(0..<3) { index in
                        let colors = [
                            ["#FF6B79", "#FFD85C", "#895CE0"], ["#4B79A1", "#283E51"], ["#A8FF78", "#78FFD6"],
                        ][index]
                        Button {
                            var frameOptions = options.imageFrame ?? .init()
                            frameOptions.backdrop = .gradient
                            frameOptions.gradientColors = colors
                            options.imageFrame = frameOptions
                        } label: {
                            RoundedRectangle(cornerRadius: 6).fill(
                                LinearGradient(
                                    colors: colors.map { Color(cgColor: ImageEngine.color($0)) },
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            ).frame(width: 60, height: 36)
                        }.buttonStyle(.plain)
                    }
                }
            }
            ColorPicker("Color", selection: colorBinding(frame(\.backgroundColor), preservingOpacity: true))
            if ImageEngine.color(options.imageFrame?.backgroundColor ?? "#FFFFFF").alpha < 1 {
                Text("Transparent backgrounds save as PNG to keep their transparency.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Button("Choose Background Image…") {
                let panel = NSOpenPanel()
                if panel.runModal() == .OK {
                    var frameOptions = options.imageFrame ?? .init()
                    frameOptions.backgroundImage = panel.url
                    frameOptions.backdrop = .image
                    options.imageFrame = frameOptions
                }
            }
            slider("Blur", value: frame(\.backgroundBlur), range: 0...60)
            slider(
                "Padding",
                value: Binding(
                    get: { Double(options.imageFrame?.padding ?? 160) },
                    set: {
                        var frameOptions = options.imageFrame ?? .init()
                        frameOptions.padding = Int($0)
                        options.imageFrame = frameOptions
                    }), range: 0...400, unit: "px")
            slider("Corners", value: frame(\.cornerRadius), range: 0...100, unit: "px")
            slider("Shadow", value: frame(\.shadowRadius), range: 0...80, unit: "px")
            HStack {
                ForEach(["Auto", "1:1", "16:9", "4:5"], id: \.self) { label in
                    Button(label) {
                        var frameOptions = options.imageFrame ?? .init()
                        let a = label.split(separator: ":").compactMap { Double($0) }
                        frameOptions.aspectRatio = a.count == 2 ? a[0] / a[1] : nil
                        options.imageFrame = frameOptions
                    }
                }
            }
        }
    }

    var collageControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Style", selection: collage(\.layout)) {
                ForEach(CollageLayout.allCases, id: \.self) { LText($0.rawValue.capitalized).tag($0) }
            }
            Stepper("Columns: \(options.collage?.columns ?? 2)", value: collage(\.columns), in: 1...12)
            Picker("Canvas", selection: collage(\.aspectRatio)) {
                Text("Square · 1:1").tag(1.0)
                Text("Landscape · 16:9").tag(16.0 / 9)
                Text("Portrait · 9:16").tag(9.0 / 16)
                Text("Portrait · 4:5").tag(4.0 / 5)
            }
            number("Canvas width", value: collage(\.width))
            Picker("Image fit", selection: collage(\.imageFit)) {
                Text("Fill cells (crop edges)").tag(ImageFit.fill)
                Text("Fit whole image").tag(ImageFit.fit)
            }
            number("Spacing", value: collage(\.spacing))
            number("Outer padding", value: collage(\.outerPadding))
            slider("Corners", value: collage(\.cornerRadius), range: 0...100)
            ColorPicker("Background", selection: colorBinding(collage(\.backgroundColor), preservingOpacity: true))
            HStack {
                Button("Background Image…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK {
                        var collageOptions = options.collage ?? .init()
                        collageOptions.backgroundImage = panel.url
                        options.collage = collageOptions
                    }
                }
                if options.collage?.backgroundImage != nil {
                    Button("Remove Image") {
                        var collageOptions = options.collage ?? .init()
                        collageOptions.backgroundImage = nil
                        options.collage = collageOptions
                    }
                }
            }
            orderControls
        }
    }

    var redactionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Style", selection: $options.redactionMode) {
                Text("Solid").tag("black")
                Text("Blur").tag("blur")
                if tool == .redactImage { Text("Pixelate").tag("pixelate") }
            }.pickerStyle(.segmented)
            ColorPicker("Color", selection: colorBinding($options.backgroundColor), supportsOpacity: false)
            Text("Drag on the preview to add an area. Each area is saved into the new copy.").font(.caption)
                .foregroundStyle(.secondary)
            if tool == .redactImage {
                HStack {
                    Button("Detect Faces") { detectRedactions(faces: true) }
                    Button("Detect Text") { detectRedactions(faces: false) }
                }
            }
            if tool == .redactVideo { timeRangeFields }
            Text(options.redactions.count == 1 ? "1 area selected" : "\(options.redactions.count) areas selected")
            if tool == .redactVideo {
                ForEach(Array(options.videoRedactions.enumerated()), id: \.offset) { index, redaction in
                    HStack {
                        LText("Area \(index+1)")
                        TextField(
                            "Start",
                            value: Binding(
                                get: { options.videoRedactions[index].start },
                                set: { options.videoRedactions[index].start = $0 }), format: .number)
                        TextField(
                            "End",
                            value: Binding(
                                get: { options.videoRedactions[index].end ?? duration },
                                set: { options.videoRedactions[index].end = $0 }), format: .number)
                    }
                }
            }
            Button("Undo Area") {
                if !options.redactions.isEmpty { options.redactions.removeLast() }
                if tool == .redactVideo, !options.videoRedactions.isEmpty { options.videoRedactions.removeLast() }
            }
        }
    }
}

