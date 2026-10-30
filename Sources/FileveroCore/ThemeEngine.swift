import Foundation

/// 24-bit RGB color representation with WCAG 2.x relative luminance and blending math.
public struct ThemeRGB: Equatable, Sendable {
    public let red, green, blue: Double

    public init(hex: UInt32) {
        self.red = Double((hex >> 16) & 0xFF) / 255.0
        self.green = Double((hex >> 8) & 0xFF) / 255.0
        self.blue = Double(hex & 0xFF) / 255.0
    }

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG 2.x relative luminance of an sRGB color.
    public var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}

/// Color tokens comprising a complete application visual theme in both light and dark appearance modes.
public struct ThemePalette: Sendable {
    public let accentStart, accentEnd: ThemeRGB
    public let accentTextLight, accentTextDark: ThemeRGB
    public let canvasLight, canvasDark: ThemeRGB
    public let glowLight, glowDark: [ThemeRGB]

    public init(
        accentStart: ThemeRGB,
        accentEnd: ThemeRGB,
        accentTextLight: ThemeRGB,
        accentTextDark: ThemeRGB,
        canvasLight: ThemeRGB,
        canvasDark: ThemeRGB,
        glowLight: [ThemeRGB],
        glowDark: [ThemeRGB]
    ) {
        self.accentStart = accentStart
        self.accentEnd = accentEnd
        self.accentTextLight = accentTextLight
        self.accentTextDark = accentTextDark
        self.canvasLight = canvasLight
        self.canvasDark = canvasDark
        self.glowLight = glowLight
        self.glowDark = glowDark
    }
}

/// Available application chromatic themes and macOS accent color integrations.
public enum ThemeEngine: String, CaseIterable, Sendable {
    case aurora, prism, crystal, sunset, lagoon, orchid, graphite, system

    public var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .prism: return "Prism"
        case .crystal: return "Crystal"
        case .sunset: return "Sunset"
        case .lagoon: return "Lagoon"
        case .orchid: return "Orchid"
        case .graphite: return "Graphite"
        case .system: return "System Accent"
        }
    }

    public static func resolve(_ storedValue: String?) -> ThemeEngine {
        storedValue.flatMap(ThemeEngine.init(rawValue:)) ?? .aurora
    }

    /// Theme color palette definition.
    public var palette: ThemePalette {
        func makePalette(
            _ start: UInt32, _ end: UInt32,
            _ textLight: UInt32, _ textDark: UInt32,
            _ canvasLight: UInt32, _ canvasDark: UInt32,
            _ glowLight: [UInt32], _ glowDark: [UInt32]
        ) -> ThemePalette {
            ThemePalette(
                accentStart: .init(hex: start),
                accentEnd: .init(hex: end),
                accentTextLight: .init(hex: textLight),
                accentTextDark: .init(hex: textDark),
                canvasLight: .init(hex: canvasLight),
                canvasDark: .init(hex: canvasDark),
                glowLight: glowLight.map(ThemeRGB.init(hex:)),
                glowDark: glowDark.map(ThemeRGB.init(hex:))
            )
        }

        switch self {
        case .aurora:
            return makePalette(
                0x3451D1, 0x6E3FD8, 0x2F45B8, 0xA9B8FF, 0xEEF1FB, 0x0E1020,
                [0x9EC5FF, 0xC7B8FF, 0xFFD6E8],
                [0x22307F, 0x4A2378, 0x0C0E1C]
            )
        case .prism:
            return makePalette(
                0x5B45E8, 0x0E7C74, 0x4B36C9, 0x9EF0E6, 0xF1F0FA, 0x0B0D1A,
                [0xD9D2FF, 0xC4F3EE, 0xEDEBFF],
                [0x3B2C8F, 0x0D6E78, 0x0B0D1A]
            )
        case .crystal, .system:
            return makePalette(
                0x1F6FEB, 0x1A5FD0, 0x1A5FD0, 0x8DB8FF, 0xF3F5F8, 0x15171C,
                [0xEEF2F7, 0xD3DBE7, 0xE4EAF2],
                [0x23262D, 0x1A1D23, 0x14161B]
            )
        case .sunset:
            return makePalette(
                0xC2410C, 0xB45309, 0xB3410E, 0xFFB38A, 0xFBF3EE, 0x170F0B,
                [0xFFD9C7, 0xFFE9B8, 0xFFD1DC],
                [0x7A2E1C, 0x6B4A12, 0x160D0A]
            )
        case .lagoon:
            return makePalette(
                0x0B7A6B, 0x1F6FB2, 0x0A6E60, 0x7FE3D2, 0xEEF7F5, 0x08141A,
                [0xC6F2E6, 0xCFE8FB, 0xE3F6F1],
                [0x0B5E52, 0x0D4772, 0x07121A]
            )
        case .orchid:
            return makePalette(
                0xC2257D, 0x7B3FE4, 0xA61E6B, 0xFF9AD0, 0xFAF0F6, 0x140C17,
                [0xFFD0EA, 0xE2D4FF, 0xFFE6F2],
                [0x6E1A4F, 0x3D2380, 0x120A16]
            )
        case .graphite:
            return makePalette(
                0x4B5563, 0x6B7280, 0x3F4652, 0xC9CED6, 0xF2F3F5, 0x121316,
                [0xE4E5E8, 0xC9CCD2, 0xD8DADF],
                [0x2A2C31, 0x1D1E22, 0x0E0F12]
            )
        }
    }
}

public typealias ColorTheme = ThemeEngine

/// Contrast ratio analysis complying with accessibility specifications (WCAG 2.1 AA/AAA).
public enum ThemeContrastCalculator {
    public static func ratio(_ colorA: ThemeRGB, _ colorB: ThemeRGB) -> Double {
        let (lighter, darker) = colorA.relativeLuminance > colorB.relativeLuminance
            ? (colorA.relativeLuminance, colorB.relativeLuminance)
            : (colorB.relativeLuminance, colorA.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func readableText(on background: ThemeRGB) -> ThemeRGB {
        let white = ThemeRGB(hex: 0xFFFFFF)
        let darkInk = ThemeRGB(hex: 0x111318)
        return ratio(white, background) >= ratio(darkInk, background) ? white : darkInk
    }
}

public typealias ThemeContrast = ThemeContrastCalculator

public struct SystemAccentPalette: Equatable, Sendable {
    public let accentStart, accentEnd, onAccent, accentTextLight, accentTextDark: ThemeRGB
    
    public init(
        accentStart: ThemeRGB,
        accentEnd: ThemeRGB,
        onAccent: ThemeRGB,
        accentTextLight: ThemeRGB,
        accentTextDark: ThemeRGB
    ) {
        self.accentStart = accentStart
        self.accentEnd = accentEnd
        self.onAccent = onAccent
        self.accentTextLight = accentTextLight
        self.accentTextDark = accentTextDark
    }
}

extension ThemeContrastCalculator {
    private static let minimumContrastRatio = 4.5
    private static let searchStep = 0.02
    private static let whiteLabelDarkeningThreshold = 0.25

    public static func blend(_ colorA: ThemeRGB, _ colorB: ThemeRGB, _ fraction: Double) -> ThemeRGB {
        ThemeRGB(
            red: colorA.red + (colorB.red - colorA.red) * fraction,
            green: colorA.green + (colorB.green - colorA.green) * fraction,
            blue: colorA.blue + (colorB.blue - colorA.blue) * fraction
        )
    }

    private static func shift(_ color: ThemeRGB, toward target: ThemeRGB, until targetText: ThemeRGB) -> (ThemeRGB, Double) {
        var progress = 0.0
        while progress < 1.0, ratio(targetText, blend(color, target, progress)) < minimumContrastRatio {
            progress += searchStep
        }
        let boundedProgress = min(progress, 1.0)
        return (blend(color, target, boundedProgress), boundedProgress)
    }

    /// Derives readable gradient ends and text colors from any arbitrary macOS accent color.
    public static func systemPalette(accent: ThemeRGB) -> SystemAccentPalette {
        let white = ThemeRGB(hex: 0xFFFFFF)
        let darkInk = ThemeRGB(hex: 0x111318)
        let black = ThemeRGB(hex: 0x000000)
        let canvasPalette = ThemeEngine.system.palette
        let lighter = blend(accent, white, 0.25)
        
        let (whiteStart, shiftAmount) = shift(accent, toward: black, until: white)
        let (resolvedStart, resolvedEnd, labelColor): (ThemeRGB, ThemeRGB, ThemeRGB)
        
        if shiftAmount > whiteLabelDarkeningThreshold,
           min(ratio(darkInk, accent), ratio(darkInk, lighter)) >= minimumContrastRatio {
            (resolvedStart, resolvedEnd, labelColor) = (accent, lighter, darkInk)
        } else {
            (resolvedStart, resolvedEnd, labelColor) = (whiteStart, shift(lighter, toward: black, until: white).0, white)
        }
        
        return SystemAccentPalette(
            accentStart: resolvedStart,
            accentEnd: resolvedEnd,
            onAccent: labelColor,
            accentTextLight: shift(accent, toward: black, until: canvasPalette.canvasLight).0,
            accentTextDark: shift(accent, toward: white, until: canvasPalette.canvasDark).0
        )
    }
}

