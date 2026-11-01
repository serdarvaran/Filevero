import FileveroCore
import FileveroUpdates
import SwiftUI

// MARK: - AppUpdateViews: In-App Update Banners & Preferences

extension Notification.Name {
    public static let showUpdateSettings = Notification.Name("FileveroShowUpdateSettings")
}

public struct AppUpdateBanner: View {
    @Environment(\.fileveroTheme) private var theme
    @ObservedObject public var updater: SparkleUpdateCoordinator
    public let version: String

    public init(updater: SparkleUpdateCoordinator, version: String) {
        self.updater = updater
        self.version = version
    }

    public var body: some View {
        let _ = theme
        HStack(spacing: 13) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 27))
                .foregroundStyle(FileveroPalette.accentText)
            VStack(alignment: .leading, spacing: 4) {
                Text("A Filevero update is available.")
                    .font(.system(size: 13, weight: .bold, design: .default))
                Text(
                    updater.waitingForCurrentTask
                        ? "Your task will finish before Filevero restarts."
                        : "Version \(version) · Install when you’re ready."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Update…") { updater.checkForUpdates() }
                .buttonStyle(FileveroButtonStyle(.secondary, compact: true))
                .disabled(!updater.canCheckForUpdates || updater.isBusy || updater.waitingForCurrentTask)
        }
        .padding(17)
        .background(
            FileveroPalette.accent.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .fileveroCard(radius: 18)
        .accessibilityElement(children: .contain)
    }
}

public struct AppUpdateSettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject public var updater: SparkleUpdateCoordinator

    public init(updater: SparkleUpdateCoordinator) {
        self.updater = updater
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FileveroPageHeading(
                    eyebrow: "Updates",
                    title: "Keep Filevero up to date.",
                    subtitle: "Check for updates and choose when to install them.")

                HStack(spacing: 17) {
                    FileveroMark(size: 62, happy: updater.availableVersion != nil)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Filevero \(version)").font(.system(size: 21, weight: .bold, design: .default))
                        Text("Build \(build)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.availableVersion != nil {
                        FileveroPill(title: "Update ready", symbol: "sparkle")
                    }
                }
                .padding(22)
                .fileveroCard()

                if let error = updater.configurationError {
                    GroupBox("Updates are being set up") {
                        LText(error).font(.system(size: 13)).foregroundStyle(.secondary).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(10)
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 17) {
                            Toggle(
                                "Check for updates automatically",
                                isOn: Binding(
                                    get: { updater.automaticallyChecksForUpdates },
                                    set: updater.setAutomaticChecks))
                            Text("Filevero checks once an hour while it’s running and asks before installing an update.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    LText(statusTitle).font(.headline)
                                    if let date = updater.lastCheckedAt {
                                        Text("Last checked \(AppLocalization.dateTime(date, language: locale.identifier))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No update checks yet").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(updater.availableVersion == nil ? "Check for Updates…" : "Update…") {
                                    updater.checkForUpdates()
                                }
                                .buttonStyle(FileveroButtonStyle(.primary))
                                .disabled(!updater.canCheckForUpdates || updater.isBusy || updater.waitingForCurrentTask)
                            }

                            if updater.isBusy {
                                Label(
                                    "Your current task will finish before an update restarts the app.",
                                    systemImage: "hourglass"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let error = updater.lastError {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                    }
                }
                Label(
                    "Updates are verified before installation. Your settings and recent history stay with you.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(27)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .fileveroAnimation(value: updater.availableVersion)
    }

    private var statusTitle: String {
        if updater.waitingForCurrentTask { return "Ready after your current task" }
        if let version = updater.availableVersion { return "Version \(version) is available" }
        if updater.sessionInProgress { return "Checking for updates…" }
        if updater.lastError != nil { return "The update needs another try" }
        return "Ready to check for updates"
    }
}

// MARK: - Compatibility Bridge
public typealias UpdateBanner = AppUpdateBanner
public typealias UpdateSettingsView = AppUpdateSettingsView

