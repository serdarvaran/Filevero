import AppKit
import FileveroCore
import ServiceManagement
import SwiftUI

// MARK: - OnboardingWelcomeView: First-Run Multi-Step Guided Tour

public struct OnboardingWelcomeView: View {
    public let onDone: () -> Void
    public let onClose: () -> Void
    public let onMinimize: () -> Void
    @State private var page: Int

    public init(
        onDone: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onMinimize: @escaping () -> Void,
        initialPage: Int = 0
    ) {
        self.onDone = onDone
        self.onClose = onClose
        self.onMinimize = onMinimize
        _page = State(initialValue: initialPage)
    }

    @State private var folderAllowed = false
    @State private var folderError: String?
    @State private var launchAtLogin = false
    @State private var launchNeedsApproval = false
    @State private var launchUnavailable = false
    @State private var launchError: String?
    @Environment(\.fileveroTheme) private var theme

    private let names = ["Welcome", "Convert", "Edit", "Actions", "Folders", "Ready"]
    private var toolsReady: Bool { ExternalToolSetup.status.ready }

    private var titles: [String] {
        [
            "One drop away from the right format.",
            "Change the format.",
            "Make it yours.",
            "Send it further.",
            "Choose where to work.",
            toolsReady ? "Everything is ready." : "Finish setting up.",
        ]
    }

    private var shortcut: KeyboardModifierChord {
        KeyboardModifierPreferences.chord(for: page == 1 ? .conversions : page == 2 ? .tools : .actions)
    }

    public var body: some View {
        let _ = theme
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                .accessibilityLabel("Close welcome")
                .keyboardShortcut(.cancelAction)

                ZStack {
                    WindowDragRegion()
                    HStack(spacing: 8) {
                        FileveroMark(size: 24)
                        Text(verbatim: "Filevero").font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                Button("Skip introduction", action: onDone)
                    .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            HStack(spacing: 30) {
                artwork.frame(width: 250, height: 290).id("art-\(page)").transition(.opacity)
                VStack(alignment: .leading, spacing: 15) {
                    FileveroPill(title: names[page], symbol: page == 5 ? "checkmark" : "sparkle")
                    LText(titles[page]).font(.system(size: 30, weight: .bold)).tracking(-0.7).fixedSize(
                        horizontal: false, vertical: true)
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("copy-\(page)")
                .transition(.opacity)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileveroGlass(radius: 28)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    ForEach(0..<6, id: \.self) { index in
                        Button {
                            page = index
                        } label: {
                            Capsule().fill(
                                index <= page
                                    ? AnyShapeStyle(FileveroPalette.accentGradient)
                                    : AnyShapeStyle(FileveroPalette.fill)
                            ).frame(width: index == page ? 30 : 18, height: 6).frame(height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Step \(index + 1) of 6: \(L10n.text(names[index]))")
                        .accessibilityAddTraits(page == index ? .isSelected : [])
                    }
                }
                Text("\(page + 1) / 6").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }.buttonStyle(FileveroButtonStyle(.secondary))
                }
                Button(action: page == 5 ? onDone : next) {
                    Label(
                        page == 5 ? (toolsReady ? "Open Filevero" : "Review tools") : "Continue",
                        systemImage: "arrow.right")
                }
                .buttonStyle(FileveroButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 22)
        }
        .frame(width: 760, height: 520)
        .fileveroBackdrop()
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(FileveroPalette.stroke))
        .tint(FileveroPalette.accent)
        .fileveroAnimation(value: page)
        .onAppear {
            folderAllowed = !FolderAccessPreferences.grants().isEmpty
            readLaunchStatus()
        }
        .onChange(of: page) { if $0 == 5 { readLaunchStatus() } }
    }

    private var artwork: some View {
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [FileveroPalette.accent.opacity(0.42), FileveroPalette.accentEnd.opacity(0.14), .clear],
                    center: .center, startRadius: 0, endRadius: 150)
            ).frame(width: 300, height: 300)
            if page == 0 || page == 5 {
                FileveroMark(size: 128, happy: page == 5)
            } else if page == 4 {
                symbolTile(folderAllowed ? "folder.badge.checkmark" : "folder.fill")
                    .fileveroAnimation(value: folderAllowed)
            } else {
                VStack(spacing: 10) {
                    symbolTile(
                        page == 1 ? "arrow.triangle.2.circlepath" : page == 2 ? "slider.horizontal.3" : "paperplane"
                    ).padding(.bottom, 6)
                    ForEach(
                        page == 1
                            ? ["PNG → WEBP", "MOV → MP4", "PDF → EPUB"]
                            : page == 2 ? ["Crop", "Compress", "Annotate"] : ["Copy", "Move", "Share"], id: \.self
                    ) { title in
                        LText(title)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 170, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .fileveroGlassCapsule()
                    }
                }
            }
        }.accessibilityHidden(true)
    }

    private func symbolTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(FileveroPalette.onAccent)
            .frame(width: 72, height: 72)
            .background(
                FileveroPalette.accentGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: FileveroPalette.accent.opacity(0.4), radius: 16, y: 6)
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case 0:
            LText("Convert, edit and organize files from one place on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Processing happens on your Mac. Web downloads require a connection.", systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(FileveroPalette.accentText)
                .fixedSize(horizontal: false, vertical: true)
        case 1, 2, 3:
            LText(
                page == 1
                    ? "Drag a file in Finder, then tap your conversion shortcut to choose a format."
                    : page == 2
                        ? "Drag a file in Finder, then tap your tools shortcut to edit, crop or compress it."
                        : "Drag a file in Finder, then tap your actions shortcut to copy, move or share it."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(shortcut.symbols).font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your shortcut").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(verbatim: shortcut.title).font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(12)
            .fileveroGlass(radius: 14)
            Text("You can change shortcuts in Settings.").font(.system(size: 11)).foregroundStyle(.secondary)
        case 4:
            LText("Allow access to a folder where you save files. By default, results are saved beside the originals.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: chooseFolder) {
                Label(
                    folderAllowed ? "Folder access ready" : "Choose a folder",
                    systemImage: folderAllowed ? "checkmark" : "folder.badge.plus")
            }
            .buttonStyle(FileveroButtonStyle())
            Text("Optional. Manage folder access later in Settings.").font(.system(size: 11)).foregroundStyle(.secondary)
            if let folderError {
                Text(folderError).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        default:
            LText(
                toolsReady
                    ? "Select a file to get started, or drag one in Finder to open your shortcuts."
                    : "Some conversions and web downloads need additional tools. Continue to review and install the missing tools."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: updateLaunch))
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .disabled(launchUnavailable)

            if launchNeedsApproval {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
            }
            if launchUnavailable {
                Text("Launch at login is unavailable for this copy.").font(.caption).foregroundStyle(.secondary)
            }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private func next() { page = min(5, page + 1) }

    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = L10n.text("Allow Home Folder Access")
        picker.message = L10n.text("Choose your home folder or a folder where you save files.")
        picker.prompt = L10n.text("Allow Access")
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            try FolderAccessPreferences.add([url])
            folderAllowed = true
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    private func readLaunchStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchNeedsApproval = status == .requiresApproval
        launchUnavailable = status == .notFound
    }

    private func updateLaunch(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        readLaunchStatus()
    }
}

// MARK: - Compatibility Bridge
public typealias WelcomeView = OnboardingWelcomeView

