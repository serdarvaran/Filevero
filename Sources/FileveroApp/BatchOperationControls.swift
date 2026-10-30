import AppKit
import FileveroCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings inspector for offline batch operations and conversions that do not require live canvas previews.
public struct BatchOperationControls: View {
    public let tool: ToolKind
    public let includesPDF: Bool
    @Binding public var options: OperationOptions
    @Binding public var confirmation: String
    public let color: (Binding<String>) -> Binding<Color>

    public init(
        tool: ToolKind,
        includesPDF: Bool,
        options: Binding<OperationOptions>,
        confirmation: Binding<String>,
        color: @escaping (Binding<String>) -> Binding<Color>
    ) {
        self.tool = tool
        self.includesPDF = includesPDF
        self._options = options
        self._confirmation = confirmation
        self.color = color
    }

    public var body: some View {
        switch tool {
        case .watermark: watermarkSection
        case .uniformSize: uniformSizeSection
        case .createAnimation: animationSection
        case .pageNumbers: pageNumbersSection
        case .protectPDF: passwordSection(isConfirming: true)
        case .unlockPDF: passwordSection(isConfirming: false)
        case .videoSnapshots:
            VStack(alignment: .leading, spacing: 8) {
                Slider(
                    value: Binding(get: { options.snapshotFraction ?? 0.1 }, set: { options.snapshotFraction = $0 }),
                    in: 0...1
                ) { Text("Position") }
                LText("One frame from each video at \(Int((options.snapshotFraction ?? 0.1) * 100))% of its length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    public static func isReady(_ tool: ToolKind, options: OperationOptions, confirmation: String) -> Bool {
        switch tool {
        case .protectPDF:
            return options.password.count >= 4 && options.password == confirmation
        case .unlockPDF:
            return !options.password.isEmpty
        case .watermark:
            let mark = options.watermark ?? .init()
            return mark.logo != nil || !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private var watermarkOptionsBinding: Binding<WatermarkOptions> {
        Binding(get: { options.watermark ?? .init() }, set: { options.watermark = $0 })
    }

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let logo = watermarkOptionsBinding.wrappedValue.logo {
                HStack {
                    Image(systemName: "photo")
                    Text(verbatim: logo.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Change…") { chooseWatermarkLogo() }
                    Button("Use text") { watermarkOptionsBinding.wrappedValue.logo = nil }
                }
            } else {
                HStack {
                    TextField("Watermark text", text: watermarkOptionsBinding.text)
                    Button("Use a logo…") { chooseWatermarkLogo() }
                }
                ColorPicker("Color", selection: color(watermarkOptionsBinding.color))
            }
            Picker("Position", selection: watermarkOptionsBinding.position) {
                ForEach(WatermarkPosition.allCases, id: \.self) { LText($0.title).tag($0) }
            }
            percentageSlider("Size", value: watermarkOptionsBinding.scale, range: 0.05...1)
            percentageSlider("Opacity", value: watermarkOptionsBinding.opacity, range: 0.05...1)
            if includesPDF { pdfNotice }
        }
    }

    private func chooseWatermarkLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            watermarkOptionsBinding.wrappedValue.logo = url
        }
    }

    private func percentageSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            LText(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private var uniformSizeBinding: Binding<UniformSizeOptions> {
        Binding(get: { options.uniformSize ?? .init() }, set: { options.uniformSize = $0 })
    }

    private var uniformSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Square") {
                    uniformSizeBinding.wrappedValue.width = 1080
                    uniformSizeBinding.wrappedValue.height = 1080
                }
                Button("Portrait") {
                    uniformSizeBinding.wrappedValue.width = 1080
                    uniformSizeBinding.wrappedValue.height = 1350
                }
                Button("Story") {
                    uniformSizeBinding.wrappedValue.width = 1080
                    uniformSizeBinding.wrappedValue.height = 1920
                }
                Button("Wide") {
                    uniformSizeBinding.wrappedValue.width = 1920
                    uniformSizeBinding.wrappedValue.height = 1080
                }
            }
            HStack {
                Text("Width")
                TextField("Width", value: uniformSizeBinding.width, format: .number).frame(width: 80)
                Text("Height")
                TextField("Height", value: uniformSizeBinding.height, format: .number).frame(width: 80)
                Text("px").foregroundStyle(.secondary)
            }
            Picker("Fit", selection: uniformSizeBinding.mode) {
                Text("Show whole image").tag(UniformSizeMode.fit)
                Text("Fill and crop").tag(UniformSizeMode.fill)
            }.pickerStyle(.segmented)
            if uniformSizeBinding.wrappedValue.mode == .fit {
                ColorPicker("Background", selection: color(uniformSizeBinding.background))
            }
        }
    }

    private var animationBinding: Binding<AnimationOptions> {
        Binding(get: { options.animation ?? .init() }, set: { options.animation = $0 })
    }

    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: animationBinding.format) {
                Text("GIF").tag("gif")
                Text("MP4 video").tag("mp4")
            }.pickerStyle(.segmented)
            Stepper(value: animationBinding.secondsPerImage, in: 0.1...10, step: 0.1) {
                LText("Each image: \(String(format: "%.1f", animationBinding.wrappedValue.secondsPerImage)) s")
            }
            Picker("Size", selection: animationBinding.maxDimension) {
                Text("480 px").tag(480)
                Text("720 px").tag(720)
                Text("1080 px").tag(1080)
            }
            LText("Images follow the selection order and take the first image's proportions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pageNumbersBinding: Binding<PageNumberOptions> {
        Binding(get: { options.pageNumbers ?? .init() }, set: { options.pageNumbers = $0 })
    }

    private var pageNumbersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Position", selection: pageNumbersBinding.position) {
                ForEach(PageNumberPosition.allCases, id: \.self) { LText($0.title).tag($0) }
            }
            Stepper(value: pageNumbersBinding.startNumber, in: 0...9999) {
                LText("Start at \(pageNumbersBinding.wrappedValue.startNumber)")
            }
            Toggle("Show page count, for example 3 / 12", isOn: pageNumbersBinding.showTotal)
            Stepper(value: pageNumbersBinding.fontSize, in: 6...36) {
                LText("Text size \(Int(pageNumbersBinding.wrappedValue.fontSize)) pt")
            }
            pdfNotice
        }
    }

    private var pdfNotice: some View {
        Text("Bookmarks and links between pages are not kept; web links are.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func passwordSection(isConfirming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Password", text: $options.password)
            if isConfirming {
                SecureField("Repeat password", text: $confirmation)
                if !confirmation.isEmpty, confirmation != options.password {
                    Text("The passwords do not match.").font(.caption).foregroundStyle(.orange)
                }
                Text("Use at least 4 English letters, digits or symbols. Keep the password safe; it cannot be recovered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter the current password. The copy opens without one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Backward-compatibility alias
public typealias BatchToolControls = BatchOperationControls

