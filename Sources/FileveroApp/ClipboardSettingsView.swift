import AppKit
import FileveroCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ClipboardSettingsView: Clipboard History Preferences

struct ClipboardSettingsView: View {
    @ObservedObject var controller: ClipboardController
    @AppStorage(ClipboardController.Key.enabled) private var enabled = false
    @AppStorage(ClipboardController.Key.clearOnRestart) private var clearOnRestart = true
    @AppStorage(ClipboardController.Key.limit) private var limit = 200
    @AppStorage(ClipboardController.Key.shortcut) private var shortcut = ClipboardShortcut.controlCommandV.rawValue
    @State private var confirmingTurnOff = false
    @State private var confirmingClear: ClearScope?
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    private enum ClearScope: Identifiable {
        case unpinned, all
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FileveroPageHeading(
                    eyebrow: "Clipboard",
                    title: "Everything you copy, close at hand.",
                    subtitle: "Filevero keeps what you copy on this Mac and pastes it back with a shortcut. Nothing leaves your computer.")

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Use clipboard history", isOn: Binding(get: { enabled }, set: setEnabled))
                        if enabled { options }
                    }
                    .padding(10)
                }

                if enabled {
                    GroupBox("Permissions") {
                        VStack(alignment: .leading, spacing: 12) {
                            permissionRow(
                                accessibilityTrusted ? "Pastes into the app you were using." : "Without Accessibility access, Filevero copies the item and you press ⌘V.",
                                ready: accessibilityTrusted,
                                settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                            if let note = pasteboardNote {
                                permissionRow(note, ready: false, settings: "x-apple.systempreferences:com.apple.preference.security")
                            }
                        }
                        .padding(10)
                    }
                    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                        accessibilityTrusted = AXIsProcessTrusted()
                    }

                    GroupBox("Excluded apps") {
                        excludedApps.padding(10)
                    }

                    HStack {
                        Button("Clear Unpinned…") { confirmingClear = .unpinned }
                        Button("Clear All…") { confirmingClear = .all }
                    }
                }
            }
            .padding(27)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Turn off clipboard history?", isPresented: $confirmingTurnOff) {
            Button("Turn Off and Delete History", role: .destructive) { controller.setEnabled(false, keepHistory: false) }
            Button("Turn Off, Keep History") { controller.setEnabled(false, keepHistory: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            confirmingClear == .all ? "Delete all clipboard history, including pinned items?" : "Delete clipboard history except pinned items?",
            isPresented: Binding(get: { confirmingClear != nil }, set: { if !$0 { confirmingClear = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if confirmingClear == .all { controller.clearAll() } else { controller.clearUnpinned() }
                confirmingClear = nil
            }
            Button("Cancel", role: .cancel) { confirmingClear = nil }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Shortcut", selection: $shortcut) {
                ForEach(ClipboardShortcut.allCases, id: \.rawValue) { Text(verbatim: $0.rawValue).tag($0.rawValue) }
            }
            .fixedSize()
            if let warning = ClipboardShortcut.stored(shortcut).conflictWarning {
                Label(L10n.text(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = controller.shortcutError {
                Label(L10n.text(error), systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.orange)
            }
            Picker("Keep up to", selection: $limit) {
                ForEach([50, 100, 200, 500], id: \.self) { Text(L10n.text("\($0) items")).tag($0) }
            }
            .fixedSize()
            Toggle("Clear history when you sign out, shut down or restart (pinned items stay)", isOn: $clearOnRestart)
            LText("Passwords copied from password managers are never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.excludedApps, id: \.self) { bundleID in
                HStack {
                    Text(verbatim: appName(bundleID))
                    Spacer()
                    Button {
                        controller.setExcludedApps(controller.excludedApps.filter { $0 != bundleID })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove"))
                }
            }
            Button("Add App…", action: addApp)
        }
    }

    private var pasteboardNote: String? {
        guard #available(macOS 15.4, *) else { return nil }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return nil
        default:
            return "Allow Filevero to read the clipboard in System Settings → Privacy & Security → Paste from Other Apps."
        }
    }

    private func permissionRow(_ text: String, ready: Bool, settings: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? FileveroPalette.accentText : .orange)
            LText(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !ready, let url = URL(string: settings) {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func setEnabled(_ value: Bool) {
        if value { controller.setEnabled(true) } else { confirmingTurnOff = true }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !controller.excludedApps.contains(id)
        else { return }
        controller.setExcludedApps(controller.excludedApps + [id])
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
