import AppKit
import FileveroCore
import SwiftUI

/// Unified palette and styling tokens supporting dynamic liquid glass aesthetics,
/// custom theme accents, and macOS accessibility contrast adjustments.
public enum ThemeTokenPalette {
    public static var currentTheme: ColorTheme {
        ColorTheme.resolve(UserDefaults.standard.string(forKey: "colorTheme"))
    }

    public static func nsColor(from rgb: ThemeRGB, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    public static func dynamicAdaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func convertToRGB(_ color: NSColor) -> ThemeRGB {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return ThemeRGB(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }

    public static var liveSystemPalette: SystemAccentPalette {
        ThemeContrast.systemPalette(accent: convertToRGB(.controlAccentColor))
    }

    public static func accentDuo(_ theme: ColorTheme = currentTheme) -> (NSColor, NSColor) {
        guard theme == .system else {
            return (nsColor(from: theme.palette.accentStart), nsColor(from: theme.palette.accentEnd))
        }
        let system = liveSystemPalette
        return (nsColor(from: system.accentStart), nsColor(from: system.accentEnd))
    }

    public static var primaryAccentNS: NSColor { accentDuo().0 }
    public static var secondaryAccentNS: NSColor { accentDuo().1 }
    public static var primaryAccent: Color { Color(nsColor: primaryAccentNS) }
    public static var secondaryAccent: Color { Color(nsColor: secondaryAccentNS) }

    public static var accentGradient: LinearGradient {
        LinearGradient(colors: [primaryAccent, secondaryAccent], startPoint: .leading, endPoint: .trailing)
    }

    public static var onAccentTextNS: NSColor {
        if currentTheme == .system {
            return nsColor(from: liveSystemPalette.onAccent)
        }
        let (start, end) = accentDuo()
        let startRGB = convertToRGB(start)
        let endRGB = convertToRGB(end)
        let brighter = startRGB.relativeLuminance > endRGB.relativeLuminance ? startRGB : endRGB
        return nsColor(from: ThemeContrast.readableText(on: brighter))
    }
    public static var onAccentText: Color { Color(nsColor: onAccentTextNS) }

    public static var dynamicAccentTextNS: NSColor {
        guard currentTheme != .system else {
            return dynamicAdaptive(light: nsColor(from: liveSystemPalette.accentTextLight), dark: nsColor(from: liveSystemPalette.accentTextDark))
        }
        return dynamicAdaptive(light: nsColor(from: currentTheme.palette.accentTextLight), dark: nsColor(from: currentTheme.palette.accentTextDark))
    }
    public static var dynamicAccentText: Color { Color(nsColor: dynamicAccentTextNS) }

    public static func canvasBackgroundNS(_ theme: ColorTheme = currentTheme) -> NSColor {
        dynamicAdaptive(light: nsColor(from: theme.palette.canvasLight), dark: nsColor(from: theme.palette.canvasDark))
    }
    public static var canvasBackground: Color { Color(nsColor: canvasBackgroundNS()) }

    public static func ambientGlowColors(isDark: Bool, _ theme: ColorTheme = currentTheme) -> [Color] {
        (isDark ? theme.palette.glowDark : theme.palette.glowLight).map { Color(nsColor: nsColor(from: $0)) }
    }

    public static let glassEdgeStroke = Color(nsColor: dynamicAdaptive(light: NSColor(white: 1, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.14)))
    public static let subtleBorder = Color.primary.opacity(0.08)
    public static let surfaceFill = Color.primary.opacity(0.05)
    public static let successTint = Color.green

    public static func apply() {}
}

// Backward-compatibility bridge
public typealias FileveroPalette = ThemeTokenPalette
public typealias FileveroAppearanceTheme = ThemeTokenPalette

public extension ThemeTokenPalette {
    static var theme: ColorTheme { currentTheme }
    static func ns(_ rgb: ThemeRGB, alpha: CGFloat = 1) -> NSColor { nsColor(from: rgb, alpha: alpha) }
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor { dynamicAdaptive(light: light, dark: dark) }
    static var systemPalette: SystemAccentPalette { liveSystemPalette }
    static func accentPair(_ theme: ColorTheme = currentTheme) -> (NSColor, NSColor) { accentDuo(theme) }
    static var nsAccent: NSColor { primaryAccentNS }
    static var nsAccentEnd: NSColor { secondaryAccentNS }
    static var accent: Color { primaryAccent }
    static var accentEnd: Color { secondaryAccent }
    static var nsOnAccent: NSColor { onAccentTextNS }
    static var onAccent: Color { onAccentText }
    static var nsAccentText: NSColor { dynamicAccentTextNS }
    static var accentText: Color { dynamicAccentText }
    static func nsCanvas(_ theme: ColorTheme = currentTheme) -> NSColor { canvasBackgroundNS(theme) }
    static var canvas: Color { canvasBackground }
    static func glow(dark: Bool, _ theme: ColorTheme = currentTheme) -> [Color] { ambientGlowColors(isDark: dark, theme) }
    static var stroke: Color { glassEdgeStroke }
    static var border: Color { subtleBorder }
    static var fill: Color { surfaceFill }
    static var success: Color { successTint }
}

public struct FileveroThemeKey: EnvironmentKey {
    public static let defaultValue = ColorTheme.aurora.rawValue
}

public extension EnvironmentValues {
    var fileveroTheme: String {
        get { self[FileveroThemeKey.self] }
        set { self[FileveroThemeKey.self] = newValue }
    }
}

public enum FileveroMotion {
    public static var enabled: Bool {
        !UserDefaults.standard.bool(forKey: "reduceAnimations") && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

public enum FileveroTransparency {
    public static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || UserDefaults.standard.bool(forKey: "reduceTransparency")
    }
}

public enum FileveroAppearance {
    @MainActor public static func apply(_ selection: String? = nil) {
        let choice = selection ?? UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
        NSApp.appearance = choice == "light"
            ? NSAppearance(named: .aqua)
            : choice == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

public struct FileveroMotionModifier<Value: Equatable>: ViewModifier {
    public let value: Value
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @AppStorage("reduceAnimations") private var userReducedMotion = false

    public func body(content: Content) -> some View {
        content.animation(
            systemReducedMotion || userReducedMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88),
            value: value
        )
    }
}

public struct FileveroEntrance: ViewModifier {
    public var delay: Double = 0.0
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @AppStorage("reduceAnimations") private var userReducedMotion = false

    public func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || systemReducedMotion || userReducedMotion ? 0 : 8)
            .onAppear {
                if systemReducedMotion || userReducedMotion {
                    isVisible = true
                } else {
                    withAnimation(.easeOut(duration: 0.24).delay(delay)) {
                        isVisible = true
                    }
                }
            }
    }
}

public extension View {
    func fileveroAnimation<V: Equatable>(value: V) -> some View {
        modifier(FileveroMotionModifier(value: value))
    }

    func fileveroEntrance(delay: Double = 0) -> some View {
        modifier(FileveroEntrance(delay: delay))
    }
}

