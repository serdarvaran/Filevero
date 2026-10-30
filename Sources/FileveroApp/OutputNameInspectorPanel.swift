import FileveroCore
import SwiftUI

// MARK: - OutputNameInspectorPanel: Batch Target Naming & Collision Inspector

public struct OutputNameInspectorPanel: View {
    public let inputs: [URL]
    public let formats: [String]
    @AppStorage(OutputNamePreference.key) private var template = ""
    @State private var format: String?
    @State private var expanded: Bool
    private static let visibleRows = 8

    public init(inputs: [URL], formats: [String], expanded: Bool = false) {
        self.inputs = inputs
        self.formats = formats
        _expanded = State(initialValue: expanded)
    }

    public var body: some View {
        let selected = format.flatMap { formats.contains($0) ? $0 : nil } ?? formats.first
        if let selected,
            let rows = try? OutputNamePreview.preview(
                inputs, format: selected, template: OutputNamePreference.template(from: template))
        {
            let conflicts = rows.filter { $0.status != .available }.count
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                        conflicts == 0
                            ? LText("Output names are free").font(.caption)
                            : LText("\(conflicts) names will get a number").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")

                if expanded {
                    Picker("Format", selection: Binding(get: { selected }, set: { format = $0 })) {
                        ForEach(formats, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    .labelsHidden()

                    ForEach(Array(rows.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 6) {
                            icon(row.status).frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: row.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                if row.status != .available {
                                    Text(
                                        row.status == .existing
                                            ? "A file with this name exists; a number is added."
                                            : "Another selected file uses this name first."
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if rows.count > Self.visibleRows {
                        LText("and \(rows.count - Self.visibleRows) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func icon(_ status: OutputNamePreview.Status) -> some View {
        switch status {
        case .available:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .existing:
            Image(systemName: "number.circle").foregroundStyle(.orange)
        case .duplicate:
            Image(systemName: "square.on.square").foregroundStyle(.orange)
        }
    }
}

// MARK: - Compatibility Bridge
public typealias OutputNamePreviewPanel = OutputNameInspectorPanel

