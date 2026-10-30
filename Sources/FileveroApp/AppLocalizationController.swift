import AppKit
import FileveroCore
import SwiftUI

public extension Notification.Name {
    static let fileveroLanguageChanged = Notification.Name("FileveroLanguageChanged")
    static let toolSetupChanged = Notification.Name("ToolSetupChanged")
}

public enum L10n {
    public static var language: String {
        AppLocalization.normalizedLanguage(UserDefaults.standard.string(forKey: "appLanguage"))
    }

    public static func text(_ value: String, language: String) -> String {
        AppLocalization.text(value, language: language)
    }

    public static func text(_ value: String) -> String {
        text(value, language: language)
    }

    private static let menuSources = NSMapTable<NSMenuItem, NSString>.weakToStrongObjects()
    private static let windowSources = NSMapTable<NSWindow, NSString>.weakToStrongObjects()

    public static func windowTitle(_ window: NSWindow, source: String) {
        windowSources.setObject(source as NSString, forKey: window)
        window.title = text(source)
    }

    public static func updateWindowTitles() {
        for window in windowSources.keyEnumerator() {
            if let targetWindow = window as? NSWindow, let sourceText = windowSources.object(forKey: targetWindow) {
                targetWindow.title = text(sourceText as String)
            }
        }
    }

    public static func menuTitle(_ item: NSMenuItem, source: String) {
        menuSources.setObject(source as NSString, forKey: item)
        item.title = text(source)
    }

    public static func localize(_ menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            let source = menuSources.object(forKey: item).map(String.init) ?? item.title
            menuTitle(item, source: source)
            localize(item.submenu)
        }
    }
}

private struct LocalizedRoot<Content: View>: View {
    let content: Content
    @AppStorage("appLanguage") private var selectedLanguage = "en"
    @AppStorage("colorTheme") private var selectedTheme = ColorTheme.aurora.rawValue

    var body: some View {
        content
            .environment(\.locale, Locale(identifier: AppLocalization.normalizedLanguage(selectedLanguage)))
            .environment(\.fileveroTheme, ColorTheme.resolve(selectedTheme).rawValue)
            .tint(ThemeTokenPalette.primaryAccent)
    }
}

public extension View {
    func fileveroLanguage() -> some View {
        LocalizedRoot(content: self)
    }
}

public struct LText: View {
    public let source: String
    @AppStorage("appLanguage") private var activeLanguage = "en"

    public init(_ source: String) {
        self.source = source
    }

    public var body: some View {
        Text(verbatim: L10n.text(source, language: activeLanguage))
    }
}

