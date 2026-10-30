import AppKit
import FileveroCore
import SwiftUI

/// Ambient radial light field producing liquid glass depth under elevated surfaces.
public struct FileveroBackdrop: View {
    public var theme: ColorTheme? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fileveroTheme) private var activeThemeIdentifier

    public init(theme: ColorTheme? = nil) {
        self.theme = theme
    }

    public var body: some View {
        let activeTheme = theme ?? ColorTheme.resolve(activeThemeIdentifier)
        let glowTints = ThemeTokenPalette.ambientGlowColors(isDark: colorScheme == .dark, activeTheme)

        GeometryReader { proxy in
            let area = proxy.size
            let dimension = max(area.width, area.height)

            ZStack {
                Color(nsColor: ThemeTokenPalette.canvasBackgroundNS(activeTheme))

                ZStack {
                    radialOrb(glowTints[0], size: dimension * 0.95)
                        .position(x: area.width * 0.12, y: area.height * 0.08)
                    radialOrb(glowTints[1], size: dimension * 0.80)
                        .position(x: area.width * 0.92, y: area.height * 0.38)
                    radialOrb(glowTints[2], size: dimension * 0.90)
                        .position(x: area.width * 0.42, y: area.height * 1.02)
                }
                .opacity(colorScheme == .dark ? 0.9 : 0.8)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func radialOrb(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0.55), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }
}

public struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    public let shape: S
    public let isInteractive: Bool
    @Environment(\.accessibilityReduceTransparency) private var systemTransparencyReduced

    public init(shape: S, isInteractive: Bool = false) {
        self.shape = shape
        self.isInteractive = isInteractive
    }

    @ViewBuilder public func body(content: Content) -> some View {
        if systemTransparencyReduced || FileveroTransparency.reduced {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(ThemeTokenPalette.subtleBorder))
        } else {
            #if compiler(>=6.2)
                // Liquid Glass needs the macOS 26 SDK (Xcode 26); older toolchains build the material fallback.
                if #available(macOS 26.0, *) {
                    content
                        .glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
                        .overlay(shape.strokeBorder(ThemeTokenPalette.glassEdgeStroke, lineWidth: 0.8))
                } else {
                    materialFallback(content)
                }
            #else
                materialFallback(content)
            #endif
        }
    }

    private func materialFallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(ThemeTokenPalette.glassEdgeStroke, lineWidth: 1))
    }
}

public extension View {
    func fileveroBackdrop() -> some View {
        background(FileveroBackdrop())
    }

    func fileveroGlass(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), isInteractive: interactive))
    }

    func fileveroGlassCapsule(interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurface(shape: Capsule(), isInteractive: interactive))
    }

    func fileveroCard(radius: CGFloat = 16) -> some View {
        fileveroGlass(radius: radius)
    }
}

public enum FileveroButtonKind {
    case primary
    case secondary
    case quiet
}

public struct FileveroButtonStyle: ButtonStyle {
    public var kind: FileveroButtonKind
    public var compact: Bool

    public init(_ kind: FileveroButtonKind = .secondary, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        FileveroButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct FileveroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FileveroButtonKind
    let compact: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.accessibilityReduceTransparency) private var systemTransparencyReduced
    @AppStorage("reduceAnimations") private var userReducedMotion = false
    @Environment(\.fileveroTheme) private var activeTheme

    private var isPrimary: Bool { kind == .primary }
    private var isStaticMotion: Bool { systemReducedMotion || userReducedMotion }

    var body: some View {
        let _ = activeTheme
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: compact ? 14 : 18, alignment: .center)
            .padding(.horizontal, compact ? 11 : 17)
            .padding(.vertical, compact ? 6 : 10)
            .foregroundStyle(isPrimary ? ThemeTokenPalette.onAccentText : Color.primary)
            .background {
                if isPrimary {
                    Capsule()
                        .fill(ThemeTokenPalette.accentGradient)
                        .shadow(
                            color: systemTransparencyReduced || FileveroTransparency.reduced
                                ? .clear
                                : ThemeTokenPalette.primaryAccent.opacity(0.35),
                            radius: 8,
                            y: 3
                        )
                } else if kind == .secondary {
                    Color.clear.fileveroGlassCapsule(interactive: true)
                }
            }
            .overlay(Capsule().fill(Color.primary.opacity(isHovered && !isPrimary ? 0.05 : 0)))
            .overlay(
                Capsule()
                    .strokeBorder(isFocused ? ThemeTokenPalette.dynamicAccentText : Color.clear, lineWidth: 2)
                    .padding(-3)
            )
            .scaleEffect(isStaticMotion ? 1 : configuration.isPressed ? 0.97 : isHovered && isEnabled ? 1.015 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(isStaticMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(isStaticMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
    }
}

public struct FileveroGroupBoxStyle: GroupBoxStyle {
    @Environment(\.fileveroTheme) private var activeTheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let _ = activeTheme
        VStack(alignment: .leading, spacing: 16) {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ThemeTokenPalette.dynamicAccentText)
            configuration.content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileveroCard(radius: 20)
    }
}

public struct FileveroMark: View {
    public var size: CGFloat = 44
    public var happy: Bool = false
    @Environment(\.fileveroTheme) private var activeTheme

    public init(size: CGFloat = 44, happy: Bool = false) {
        self.size = size
        self.happy = happy
    }

    public var body: some View {
        let _ = activeTheme
        let img = Image(nsImage: ApplicationBrandArtwork.brandMark(size: size * 2, happy: happy))
            .resizable()
            .interpolation(.high)

        Group {
            if ApplicationBrandArtwork.hasAppIcon {
                img
            } else {
                img.renderingMode(.template).foregroundStyle(ThemeTokenPalette.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct FileveroPill: View {
    public let title: String
    public var symbol: String? = nil
    @Environment(\.fileveroTheme) private var activeTheme

    public init(title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    public var body: some View {
        let _ = activeTheme
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            }
            LText(title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ThemeTokenPalette.dynamicAccentText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ThemeTokenPalette.primaryAccent.opacity(0.12), in: Capsule())
    }
}

public struct FileveroPageHeading: View {
    public let eyebrow: String
    public let title: String
    public let subtitle: String
    @Environment(\.fileveroTheme) private var activeTheme

    public init(eyebrow: String, title: String, subtitle: String) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        let _ = activeTheme
        VStack(alignment: .leading, spacing: 7) {
            LText(eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ThemeTokenPalette.dynamicAccentText)
            LText(title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
            LText(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

public struct FileveroCheck: View {
    @State private var hasAppeared = false
    @Environment(\.fileveroTheme) private var activeTheme

    public init() {}

    public var body: some View {
        let _ = activeTheme
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(ThemeTokenPalette.onAccentText)
            .frame(width: 34, height: 34)
            .background(ThemeTokenPalette.accentGradient, in: Circle())
            .scaleEffect(hasAppeared ? 1 : 0.75)
            .opacity(hasAppeared ? 1 : 0)
            .fileveroAnimation(value: hasAppeared)
            .onAppear { hasAppeared = true }
            .accessibilityHidden(true)
    }
}

public struct ThemeSwatch: View {
    public let theme: ColorTheme
    public let selected: Bool

    public init(theme: ColorTheme, selected: Bool) {
        self.theme = theme
        self.selected = selected
    }

    public var body: some View {
        let roundedRect = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                renderHalfSwatch(isDark: false)
                renderHalfSwatch(isDark: true)
            }
            .frame(height: 58)
            .clipShape(roundedRect)
            .overlay(
                roundedRect.strokeBorder(
                    selected ? ThemeTokenPalette.primaryAccent : ThemeTokenPalette.subtleBorder,
                    lineWidth: selected ? 2.5 : 1
                )
            )

            HStack(spacing: 4) {
                LText(theme.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(ThemeTokenPalette.dynamicAccentText)
                }
            }
        }
    }

    private func renderHalfSwatch(isDark: Bool) -> some View {
        let (start, end) = ThemeTokenPalette.accentDuo(theme)
        return ZStack {
            FileveroBackdrop(theme: theme).environment(\.colorScheme, isDark ? .dark : .light)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(isDark ? 0.08 : 0.45))
                    .frame(width: 12)
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: start), Color(nsColor: end)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 14, height: 14)
                    .frame(maxWidth: .infinity)
            }
            .padding(5)
            .background(Color.white.opacity(isDark ? 0.06 : 0.4), in: RoundedRectangle(cornerRadius: 7))
            .padding(8)
        }
    }
}

