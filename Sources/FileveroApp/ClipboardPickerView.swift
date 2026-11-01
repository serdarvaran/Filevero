import AppKit
import Combine
import FileveroCore
import SwiftUI

// MARK: - ClipboardPickerModel: Search, Selection and Actions for the Clipboard History Picker

@MainActor
final class ClipboardPickerModel: ObservableObject {
    enum Action: Equatable { case paste, pastePlainText, copyOnly, openInFilevero, apply(ClipboardAction) }

    @Published var query = ""
    @Published var selection = 0
    @Published private(set) var history = ClipboardHistory()
    let formats: (ClipboardEntry) -> [ClipboardFormat: Data]
    let perform: (Action, ClipboardEntry) -> Void
    let togglePin: (UUID) -> Void
    let remove: (UUID) -> Void
    let close: () -> Void
    var showActions: (ClipboardEntry) -> Void = { _ in }
    private var thumbnails: [UUID: NSImage] = [:]
    private var appNames: [String: String] = [:]
    private var subscription: AnyCancellable?

    init(
        history: AnyPublisher<ClipboardHistory, Never>, formats: @escaping (ClipboardEntry) -> [ClipboardFormat: Data],
        perform: @escaping (Action, ClipboardEntry) -> Void, togglePin: @escaping (UUID) -> Void,
        remove: @escaping (UUID) -> Void, close: @escaping () -> Void
    ) {
        self.formats = formats
        self.perform = perform
        self.togglePin = togglePin
        self.remove = remove
        self.close = close
        subscription = history.sink { [weak self] in self?.history = $0 }
    }

    /// Pinned first, then recent; the 1–9 shortcuts count across both.
    var rows: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = history.entries.filter {
            needle.isEmpty || $0.preview.lowercased().contains(needle)
                || appName($0.sourceApp)?.lowercased().contains(needle) == true
        }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }

    var selected: ClipboardEntry? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            let rows = rows
            if rows.indices.contains(digit - 1) { perform(.paste, rows[digit - 1]) }
            return true
        }
        switch (event.keyCode, command) {
        case (126, _): selection = max(0, selection - 1)
        case (125, _): selection = min(max(rows.count - 1, 0), selection + 1)
        case (36, _), (76, _):
            if let selected { perform(event.modifierFlags.contains(.shift) ? .pastePlainText : .paste, selected) }
        case (53, _): close()
        case (35, true): if let selected { togglePin(selected.id) }
        case (31, true): if let selected, [.file, .image].contains(selected.kind) { perform(.openInFilevero, selected) }
        case (17, true):
            guard let selected, !ClipboardAction.available(for: selected.kind).isEmpty else {
                NSSound.beep()
                break
            }
            showActions(selected)
        // ⌘⌫ rather than ⌫, so editing the search never deletes an item; pinned items must be unpinned first.
        case (51, true), (117, true):
            guard let selected, !selected.pinned else {
                NSSound.beep()
                break
            }
            remove(selected.id)
            selection = min(selection, max(rows.count - 1, 0))
        default: return false
        }
        objectWillChange.send()
        return true
    }

    func thumbnail(_ entry: ClipboardEntry) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        let image = formats(entry)[.png].flatMap(NSImage.init(data:))
        thumbnails[entry.id] = image
        return image
    }

    func appName(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        appNames[bundleID] = name
        return name
    }
}

// MARK: - ClipboardPickerView

struct ClipboardPickerView: View {
    @ObservedObject var model: ClipboardPickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = model.rows
        let pinnedCount = rows.filter(\.pinned).count
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onChange(of: model.query) { _ in model.selection = 0 }
            if rows.isEmpty {
                Spacer()
                LText(model.history.entries.isEmpty ? "Copy something and it appears here." : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                if index == 0 && pinnedCount > 0 { sectionTitle("Pinned") }
                                if index == pinnedCount { sectionTitle("Recent") }
                                row(entry, index: index).id(entry.id)
                            }
                        }
                    }
                    .onChange(of: model.selection) { value in
                        if rows.indices.contains(value) { proxy.scrollTo(rows[value].id) }
                    }
                }
            }
            LText("↩ Paste · ⇧↩ Plain text · ⌘T Actions · ⌘P Pin · ⌘O Open in Filevero · esc Close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(width: 420, height: 480)
        .fileveroBackdrop()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { searchFocused = true }
    }

    private func sectionTitle(_ title: String) -> some View {
        LText(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6).padding(.leading, 4)
    }

    private func row(_ entry: ClipboardEntry, index: Int) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 10) {
            if entry.kind == .image, let image = model.thumbnail(entry) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: Self.symbol(entry.kind)).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.preview.isEmpty ? " " : entry.preview).lineLimit(1)
                HStack(spacing: 4) {
                    if let name = model.appName(entry.sourceApp) { Text(verbatim: name + " ·") }
                    Text(entry.created, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 4)
            if entry.pinned { Image(systemName: "pin.fill").font(.caption) }
            if index < 9 { Text(verbatim: "⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FileveroPalette.accentGradient) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.perform(.paste, entry) }
        .contextMenu {
            Button("Paste") { model.perform(.paste, entry) }
            Button("Paste as Plain Text") { model.perform(.pastePlainText, entry) }
            Button("Copy Only") { model.perform(.copyOnly, entry) }
            Button(entry.pinned ? "Unpin" : "Pin") { model.togglePin(entry.id) }
            if [.file, .image].contains(entry.kind) {
                Button("Open in Filevero") { model.perform(.openInFilevero, entry) }
            }
            let actions = ClipboardAction.available(for: entry.kind)
            if !actions.isEmpty {
                Menu("Actions") {
                    ForEach(actions, id: \.self) { action in
                        Button(LocalizedStringKey(action.title)) { model.perform(.apply(action), entry) }
                    }
                }
            }
            Divider()
            Button("Delete") { model.remove(entry.id) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    static func symbol(_ kind: ClipboardKind) -> String {
        switch kind {
        case .file: return "doc"
        case .image: return "photo"
        case .link: return "link"
        case .richText: return "textformat"
        case .text: return "text.alignleft"
        }
    }
}
