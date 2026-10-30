import AppKit
import FileveroCore
import SwiftUI

// MARK: - BarcodeScannerModel & BarcodeScannerView: Visual Code Detection & Export

@MainActor public final class BarcodeScannerModel: ObservableObject {
    @Published public var report = QRCodeScanReport()
    @Published public var busy = false
    @Published public var progress = 0.0
    @Published public var label = ""
    @Published public var password = ""
    @Published public var copied: Set<UUID> = []
    @Published public var copiedAll = false
    @Published public var error: String?

    public let inputs: [URL]
    public let onSuccess: (SuccessNotice) -> Void
    public var token = CancellationToken()

    public init(inputs: [URL], onSuccess: @escaping (SuccessNotice) -> Void) {
        self.inputs = inputs
        self.onSuccess = onSuccess
    }

    public func scan() {
        guard !busy else { return }
        busy = true
        progress = 0
        error = nil
        copied = []
        copiedAll = false
        report = QRCodeScanReport()
        token = CancellationToken()
        let source = inputs
        let password = password
        let cancel = token
        let model = self
        Task {
            do {
                report = try await ExecutionPipeline.offload {
                    try QRCodeEngine.scan(source, password: password, token: cancel) { amount, message in
                        Task { @MainActor in
                            model.progress = amount
                            model.label = message
                        }
                    }
                }
                if report.errors.isEmpty {
                    onSuccess(
                        SuccessNotice(
                            title: "Scan complete.",
                            detail: L10n.text(
                                report.results.count == 1
                                    ? "1 QR code found." : "\(report.results.count) QR codes found.")))
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    public func copy(_ result: QRCodeMatch) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(result.text, forType: .string) {
            copied.insert(result.id)
            onSuccess(SuccessNotice(title: "QR code copied.", detail: L10n.text("Ready to paste.")))
        } else {
            error = "Could not copy the QR code."
        }
    }

    public func copyAll() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(report.results.map(\.text).joined(separator: "\n"), forType: .string) {
            copiedAll = true
            onSuccess(
                SuccessNotice(title: "QR codes copied.", detail: L10n.text("\(report.results.count) ready to paste.")))
        } else {
            error = "Could not copy the QR codes."
        }
    }

    public func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QR Codes.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
                onSuccess(.action("Report saved.", files: [url]))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

public struct BarcodeScannerView: View {
    @Environment(\.fileveroTheme) private var theme
    @StateObject private var model: BarcodeScannerModel

    @MainActor public init(inputs: [URL], onSuccess: @escaping (SuccessNotice) -> Void) {
        _model = StateObject(wrappedValue: BarcodeScannerModel(inputs: inputs, onSuccess: onSuccess))
    }

    public var body: some View {
        let _ = theme
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                WindowCloseButton().frame(width: 26, height: 26)
                ZStack {
                    WindowDragRegion()
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 23))
                            .foregroundStyle(FileveroPalette.accentText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Read QR Codes").font(.system(size: 21, weight: .bold, design: .default))
                            Text("Find and copy codes from your files.").font(.system(size: 11)).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(20)
            .background(.bar)

            Divider()

            if model.busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scanning for QR codes…").font(.system(size: 12, weight: .semibold, design: .default))
                        Text(model.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { model.token.cancel() }
                        .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                }
                .padding(20)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.report.results.isEmpty, !model.busy {
                        VStack(spacing: 13) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(FileveroPalette.accentText)
                            Text("No QR codes this time.").font(.system(size: 19, weight: .bold, design: .default))
                            Text("Try a clearer image or another PDF.").font(.system(size: 12)).foregroundStyle(
                                .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 45)
                    }

                    ForEach(model.report.results) { result in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(result.sourceName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let page = result.page {
                                    FileveroPill(title: "Page \(page)")
                                }
                                Spacer()
                                Button {
                                    model.copy(result)
                                } label: {
                                    Label(
                                        model.copied.contains(result.id) ? "Copied" : "Copy",
                                        systemImage: model.copied.contains(result.id) ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                            }
                            Text(result.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(18)
                        .fileveroCard(radius: 10)
                    }

                    ForEach(model.report.errors, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.orange)
                    }
                    if let error = model.error {
                        LText(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }

            Divider()

            if model.inputs.contains(where: { FileCategory.detect($0) == .pdf }) {
                SecureField("PDF password (if needed)", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
            }

            HStack {
                Button("Scan again") { model.scan() }
                    .disabled(model.busy)
                    .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
                Spacer()
                FileveroPill(title: "\(model.report.results.count) found")
                Button("Save report…") { model.saveReport() }
                    .disabled(model.busy)
                    .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                Button(model.copiedAll ? "Copied all" : "Copy all") { model.copyAll() }
                    .disabled(model.report.results.isEmpty)
                    .buttonStyle(FileveroButtonStyle(.primary, compact: true))
            }
            .padding(20)
            .background(.bar)
        }
        .frame(minWidth: 530, minHeight: 440)
        .fileveroBackdrop()
        .tint(FileveroPalette.accent)
        .fileveroAnimation(value: model.busy)
        .fileveroAnimation(value: model.copiedAll)
        .onAppear { model.scan() }
        .onDisappear { model.token.cancel() }
    }
}

// MARK: - Compatibility Bridge
public typealias QRCodeReaderModel = BarcodeScannerModel
public typealias QRCodeReaderView = BarcodeScannerView

