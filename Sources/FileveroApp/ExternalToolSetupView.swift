import AppKit
import FileveroCore
import SwiftUI

// MARK: - ExternalToolSetupView: Tool Bundle Installation Modal Interface

@MainActor public struct ExternalToolSetupView: View {
    @StateObject private var model: ExternalToolSetupCoordinator
    @Environment(\.fileveroTheme) private var theme
    @State private var showingLicenses = false
    public let onDone: () -> Void

    public init(model: ExternalToolSetupCoordinator, onDone: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: model)
        self.onDone = onDone
    }

    public var body: some View {
        let _ = theme
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        tile("shippingbox.and.arrow.backward", size: 54)
                        FileveroPageHeading(
                            eyebrow: "First-time setup",
                            title: "Additional tools, when you need them.",
                            subtitle: "Install only the missing tool groups. No account is required.")
                    }
                    group(
                        "Media tools",
                        symbol: "film",
                        ready: model.status.mediaReady,
                        detail:
                            "FFmpeg, ffprobe, yt-dlp and Deno enable media conversion, previews and web downloads. Approximately 180 MB. FFmpeg and yt-dlp use GPL licenses; Deno uses MIT.",
                        button: "Download media tools",
                        id: "SetupMedia",
                        action: { model.install(.media) })
                    group(
                        "Office tools",
                        symbol: "doc.text",
                        ready: model.status.officeReady,
                        detail:
                            "LibreOffice 26.8.1 enables Office document conversions. A 285 MB download; about 1 GB installed. MPL 2.0 and its included third-party licenses.",
                        button: "Download office tools",
                        id: "SetupOffice",
                        action: { model.install(.office) })
                    Button("Upstream versions, licenses and source links") { showingLicenses = true }
                        .accessibilityIdentifier("SetupLicenses")
                }
                .padding(28)
            }
            VStack(alignment: .leading, spacing: 12) {
                LText(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SetupStatus")

                if model.working {
                    if let value = model.fraction {
                        ProgressView(value: value)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    if model.working {
                        Button("Cancel setup", action: model.cancel)
                            .accessibilityIdentifier("SetupCancel")
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Button(model.status.ready ? "Continue to Filevero" : "Download missing tools") {
                        if model.status.ready { onDone() } else { model.install() }
                    }
                    .buttonStyle(FileveroButtonStyle(.primary))
                    .disabled(model.working)
                    .accessibilityIdentifier("SetupContinue")
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .fileveroGlass(radius: 22)
            .padding([.horizontal, .bottom], 14)
        }
        .frame(minWidth: 590, minHeight: 560)
        .fileveroBackdrop()
        .tint(FileveroPalette.accent)
        .buttonStyle(FileveroButtonStyle())
        .onAppear { model.refresh() }
        .sheet(isPresented: $showingLicenses) { ToolLicensesView() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private func group(
        _ title: String,
        symbol: String,
        ready: Bool,
        detail: String,
        button: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            tile(symbol, size: 38)
            VStack(alignment: .leading, spacing: 10) {
                LText(title).font(.headline)
                LText(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if ready {
                    Label("Already available on your computer", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(FileveroPalette.success)
                        .accessibilityIdentifier(id + "Ready")
                } else {
                    Button(action: action) { LText(button) }
                        .disabled(model.working)
                        .accessibilityIdentifier(id)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileveroCard(radius: 22)
    }

    private func tile(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(FileveroPalette.onAccent)
            .frame(width: size, height: size)
            .background(
                FileveroPalette.accentGradient,
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .shadow(color: FileveroPalette.accent.opacity(0.35), radius: 10, y: 4)
    }
}

extension Notification.Name {
    public static let showToolSetup = Notification.Name("FileveroShowToolSetup")
}

// MARK: - Compatibility Bridge
public typealias ToolSetupView = ExternalToolSetupView

