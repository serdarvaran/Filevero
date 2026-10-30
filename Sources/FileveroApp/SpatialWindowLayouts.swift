import AppKit
import ApplicationServices
import FileveroCore
import SwiftUI

// MARK: - SpatialWindowLayoutStore & SpatialWindowLayouts: Desktop Multi-Window Topology

@MainActor public final class SpatialWindowLayoutStore: ObservableObject {
    public static let shared = SpatialWindowLayoutStore()
    private static let key = "windowLayouts"
    private let defaults: UserDefaults
    @Published public private(set) var layouts: [WindowLayout] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layouts = defaults.decodePreservingUnreadable([WindowLayout].self, forKey: Self.key) ?? []
    }

    public func add(_ layout: WindowLayout) {
        layouts.append(layout)
        persist()
    }

    public func delete(_ layout: WindowLayout) {
        layouts.removeAll { $0.id == layout.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(layouts) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor public enum SpatialWindowLayoutManager {
    // AXUIElement references may be messaged from any thread.
    public struct OpenWindow: @unchecked Sendable {
        public let bundleID: String
        public let title: String
        public let element: AXUIElement
        public let frame: CGRect
    }

    private struct RunningApp: Sendable {
        let pid: pid_t
        let bundleID: String
    }

    /// Scans other apps' windows off the main actor: each AX query blocks until that app answers.
    public static func openWindows() async -> [OpenWindow] {
        let apps = runningApps()
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return await Task.detached(priority: .userInitiated) { openWindows(in: apps, primaryMaxY: primaryMaxY) }.value
    }

    private static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(), !app.isHidden,
                let bundleID = app.bundleIdentifier
            else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID)
        }
    }

    private nonisolated static func openWindows(in apps: [RunningApp], primaryMaxY: CGFloat) -> [OpenWindow] {
        apps.flatMap { app -> [OpenWindow] in
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.2)
            let windows = (AppWindowManager.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            return windows.compactMap { window in
                AXUIElementSetMessagingTimeout(window, 0.2)
                guard AppWindowManager.isUsable(window, pid: app.pid),
                    let frame = AppWindowManager.frame(of: window)
                else { return nil }
                let title = AppWindowManager.attribute(window, kAXTitleAttribute) as? String ?? ""
                return OpenWindow(
                    bundleID: app.bundleID,
                    title: title,
                    element: window,
                    frame: AppWindowManager.appKitFrame(frame, primaryMaxY: primaryMaxY))
            }
        }
    }

    public static func capture(named name: String) async -> WindowLayout {
        WindowLayout(
            name: name,
            windows: await openWindows().map { .init(bundleID: $0.bundleID, title: $0.title, frame: $0.frame) })
    }

    public static func apply(_ layout: WindowLayout) async -> (placed: Int, saved: Int) {
        let open = await openWindows()
        let displays = NSScreen.screens.map(\.visibleFrame)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let moves = layout.assignments(for: open.map { (bundleID: $0.bundleID, title: $0.title) }).map {
            index, saved in (window: open[index], frame: WindowGeometry.clamp(saved.frame, to: displays))
        }
        let placed = await Task.detached(priority: .userInitiated) {
            moves.filter { AppWindowManager.setFrame($0.frame, of: $0.window.element, primaryMaxY: primaryMaxY) }.count
        }.value
        return (placed, layout.windows.count)
    }
}

public struct SpatialWindowLayoutSettings: View {
    public let accessibilityTrusted: Bool
    @ObservedObject public var store: SpatialWindowLayoutStore = .shared
    @State private var name = ""
    @State private var message: String?
    @State private var scanning = false

    @MainActor
    public init(accessibilityTrusted: Bool, store: SpatialWindowLayoutStore? = nil) {
        self.accessibilityTrusted = accessibilityTrusted
        self.store = store ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved layouts").font(.headline)
            Text("Save where your apps’ windows are and put them back with one click. Windows from a disconnected display move onto a visible one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Layout name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save current layout") {
                    let layoutName = name.trimmingCharacters(in: .whitespaces)
                    scanning = true
                    Task {
                        let layout = await SpatialWindowLayoutManager.capture(named: layoutName)
                        scanning = false
                        if layout.windows.isEmpty {
                            message = "No windows to save."
                        } else {
                            store.add(layout)
                            name = ""
                            message = "Saved \(layout.windows.count) windows."
                        }
                    }
                }
                .disabled(!accessibilityTrusted || scanning || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(store.layouts) { layout in
                HStack {
                    Image(systemName: "rectangle.3.group")
                    Text(verbatim: layout.name)
                    LText("\(layout.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") {
                        scanning = true
                        Task {
                            let result = await SpatialWindowLayoutManager.apply(layout)
                            scanning = false
                            message = "Arranged \(result.placed) of \(result.saved) windows."
                        }
                    }
                    .disabled(!accessibilityTrusted || scanning)

                    Button {
                        store.delete(layout)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete layout")
                    .accessibilityLabel("Delete layout")
                }
            }

            if let message {
                LText(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Compatibility Bridge
public typealias WindowLayoutStore = SpatialWindowLayoutStore
public typealias WindowLayoutManager = SpatialWindowLayoutManager
public typealias WindowLayoutSettings = SpatialWindowLayoutSettings

