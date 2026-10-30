import FileveroCore
import SwiftUI

// MARK: - EbookOptionsInspectorView: PDF to EPUB Reflow/Fixed Layout Selector

public struct EbookOptionsInspectorView: View {
    @Environment(\.fileveroTheme) private var theme
    @ObservedObject public var state: AppSessionController
    public let inputs: [URL]
    @State private var layout = "reflowable"

    public init(state: AppSessionController, inputs: [URL]) {
        self.state = state
        self.inputs = inputs
    }

    public var body: some View {
        let _ = theme
        VStack(alignment: .leading, spacing: 22) {
            FileveroPageHeading(
                eyebrow: "PDF → EPUB",
                title: "A good read, your way.",
                subtitle: "Choose how your pages make the move."
            )
            VStack(alignment: .leading, spacing: 13) {
                Picker("Layout", selection: $layout) {
                    Text("Flexible, reflowable text").tag("reflowable")
                    Text("Keep the original pages").tag("fixed")
                }
                .pickerStyle(.radioGroup)

                Text(
                    layout == "fixed"
                        ? "Keeps the look and dimensions of each page. Best for visual layouts."
                        : "Text adapts to the reader’s screen and font size. Best for reading."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(19)
            .fileveroCard(radius: 10)

            HStack {
                Label("Your original stays safe", systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Make EPUB") {
                    var options = FormatPreferences.shared.options(for: "epub")
                    options.epubLayout = layout
                    state.execute(.convert("epub"), options: options, inputs: inputs)
                }
                .buttonStyle(FileveroButtonStyle(.primary))
                .disabled(state.working)
            }

            JobProgressView(state: state)
        }
        .padding(28)
        .frame(minWidth: 470, minHeight: 310)
        .fileveroBackdrop()
        .tint(FileveroPalette.accent)
        .fileveroAnimation(value: layout)
        .onAppear {
            layout = FormatPreferences.shared.profile(for: "epub").epubLayout
        }
    }
}

// MARK: - Compatibility Bridge
public typealias EPUBOptionsView = EbookOptionsInspectorView

