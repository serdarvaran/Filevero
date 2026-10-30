import XCTest

@testable import FileveroCore

final class ColorThemeTests: XCTestCase {
    private let white = ThemeRGB(hex: 0xFFFFFF)

    func testUnknownValuesFallBackToAurora() {
        XCTAssertEqual(ColorTheme.resolve("amber"), .aurora)
        XCTAssertEqual(ColorTheme.resolve("graphite"), .graphite)
        XCTAssertEqual(ColorTheme.resolve(nil), .aurora)
        XCTAssertEqual(ColorTheme.resolve("x"), .aurora)
        XCTAssertEqual(ColorTheme.resolve("prism"), .prism)
    }

    func testEveryThemeKeepsWhiteLabelsReadable() {
        for theme in ColorTheme.allCases {
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(white, theme.palette.accentStart), 4.5, theme.rawValue)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(white, theme.palette.accentEnd), 4.5, theme.rawValue)
        }
    }

    func testAccentTextIsReadableOnCanvas() {
        for theme in ColorTheme.allCases {
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(theme.palette.accentTextLight, theme.palette.canvasLight), 4.5, theme.rawValue)
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(theme.palette.accentTextDark, theme.palette.canvasDark), 4.5, theme.rawValue)
        }
    }

    func testReadableTextPicksHigherContrast() {
        XCTAssertEqual(ThemeContrast.readableText(on: ThemeRGB(hex: 0xFFD60A)), ThemeRGB(hex: 0x111318))
        XCTAssertEqual(ThemeContrast.readableText(on: ThemeRGB(hex: 0x3451D1)), white)
    }

    func testThemesAreDistinctAndComplete() {
        XCTAssertEqual(ColorTheme.allCases.count, 8)
        XCTAssertEqual(Set(ColorTheme.allCases.map(\.title)).count, 8)
        for theme in ColorTheme.allCases {
            XCTAssertEqual(theme.palette.glowLight.count, 3, theme.rawValue)
            XCTAssertEqual(theme.palette.glowDark.count, 3, theme.rawValue)
        }
    }
}

final class SystemAccentPaletteTests: XCTestCase {
    private let samples: [UInt32] = [0x953D96, 0xE0383E, 0xFFC600, 0x007AFF, 0x8C8C8C, 0xF7821B, 0x62BA46, 0xF74F9E]

    func testLabelsStayReadableOnBothGradientEnds() {
        for hex in samples {
            let palette = ThemeContrast.systemPalette(accent: ThemeRGB(hex: hex))
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(palette.onAccent, palette.accentStart), 4.5, String(hex, radix: 16))
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(palette.onAccent, palette.accentEnd), 4.5, String(hex, radix: 16))
        }
    }

    func testAccentTextIsReadableOnSystemCanvas() {
        let canvas = ColorTheme.system.palette
        for hex in samples {
            let palette = ThemeContrast.systemPalette(accent: ThemeRGB(hex: hex))
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(palette.accentTextLight, canvas.canvasLight), 4.5, String(hex, radix: 16))
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(palette.accentTextDark, canvas.canvasDark), 4.5, String(hex, radix: 16))
        }
    }

    func testBlueKeepsWhiteLabelsLikeTheSystem() {
        XCTAssertEqual(ThemeContrast.systemPalette(accent: ThemeRGB(hex: 0x007AFF)).onAccent, ThemeRGB(hex: 0xFFFFFF))
    }
}
