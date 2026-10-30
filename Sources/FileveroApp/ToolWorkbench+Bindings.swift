import AppKit
import FileveroCore
import SwiftUI

// MARK: - ToolWorkbench Bindings & Spatial Value Resolvers

extension ToolWorkbench {
    func frame<T>(_ key: WritableKeyPath<ImageFrameOptions, T>) -> Binding<T> {
        Binding(
            get: { (options.imageFrame ?? .init())[keyPath: key] },
            set: {
                var value = options.imageFrame ?? .init()
                value[keyPath: key] = $0
                options.imageFrame = value
            })
    }

    func collage<T>(_ key: WritableKeyPath<CollageOptions, T>) -> Binding<T> {
        Binding(
            get: { (options.collage ?? .init())[keyPath: key] },
            set: {
                var value = options.collage ?? .init()
                value[keyPath: key] = $0
                options.collage = value
            })
    }

    func relative(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue - 1 }, set: { value.wrappedValue = $0 + 1 })
    }

    func number(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 60)
        }
    }

    func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        HStack {
            LText(title).font(.callout).frame(width: 105, alignment: .leading)
            Slider(value: value, in: range).tint(FileveroPalette.accent)
            Text("\(value.wrappedValue, specifier: "%.2f") \(unit)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Button {
                value.wrappedValue =
                    [
                        "Playback speed": 1, "Target loudness": -16, "Loudness range": 11, "True peak limit": -1.5,
                        "Left volume": 1, "Right volume": 1, "Padding": 160, "Corners": 24, "Shadow": 24,
                        "Stroke width": 3, "Text size": 24,
                    ][title] ?? 0
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.caption)
            }.buttonStyle(.plain)
        }
    }

    func colorBinding(_ string: Binding<String>, preservingOpacity: Bool = false) -> Binding<Color> {
        Binding(
            get: { Color(cgColor: ImageEngine.color(string.wrappedValue)) },
            set: {
                string.wrappedValue = preservingOpacity ? ImageColorCodec.backgroundHex(NSColor($0)) : hex($0)
            })
    }

    func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }

    func timeLabel(_ time: Double) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max) else { return "—" }
        return String(format: "%02ld:%06.3f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
    }
}

