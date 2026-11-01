import FileveroCore
import SwiftUI

// MARK: - ToolLicensesView: Versions, Licenses and Sources of the Tools Set Up on First Launch

struct ToolLicense: Identifiable {
    let name: String
    let purpose: String
    let license: String
    let source: URL
    let licenseText: URL

    var id: String { name }

    // Keep in step with the pinned downloads in ExternalToolInstaller.
    static let setupTools = [
        ToolLicense(
            name: "FFmpeg 9.0 · ffprobe 9.0",
            purpose: "Media conversion, previews and video tools",
            license: "GPL v2 or later",
            source: URL(string: "https://github.com/FFmpeg/FFmpeg")!,
            licenseText: URL(string: "https://ffmpeg.org/legal.html")!),
        ToolLicense(
            name: "yt-dlp 2026.08.19",
            purpose: "Web downloads",
            license: "Unlicense; the standalone build is GPL v3 or later",
            source: URL(string: "https://github.com/yt-dlp/yt-dlp/tree/2026.08.19")!,
            licenseText: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/LICENSE")!),
        ToolLicense(
            name: "Deno 2.9.7",
            purpose: "Runs the web download helpers yt-dlp needs",
            license: "MIT",
            source: URL(string: "https://github.com/denoland/deno/tree/v2.9.7")!,
            licenseText: URL(string: "https://github.com/denoland/deno/blob/v2.9.7/LICENSE.md")!),
        ToolLicense(
            name: "LibreOffice 26.8.1",
            purpose: "Office document conversion",
            license: "MPL 2.0 and included third-party licenses",
            source: URL(string: "https://www.libreoffice.org/")!,
            licenseText: URL(string: "https://www.libreoffice.org/about-us/licenses/")!),
    ]
}

struct ToolLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FileveroPageHeading(
                        eyebrow: "Licenses",
                        title: "Tool versions and licenses.",
                        subtitle: "Filevero downloads these tools from their official sources and checks each download’s SHA-256.")
                    ForEach(ToolLicense.setupTools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: tool.name).font(.headline)
                            LText(tool.purpose).font(.callout).foregroundStyle(.secondary)
                            LText(tool.license).font(.callout)
                            HStack(spacing: 16) {
                                Link("Source code", destination: tool.source)
                                Link("License", destination: tool.licenseText)
                            }
                            .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .fileveroCard(radius: 16)
                    }
                    if let notices {
                        DisclosureGroup("All third-party notices") {
                            Text(verbatim: notices)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .font(.callout)
                    }
                }
                .padding(28)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(FileveroButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
        .fileveroBackdrop()
    }
}
