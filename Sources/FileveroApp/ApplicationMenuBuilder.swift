import AppKit
import FileveroCore

public extension Notification.Name {
    static let showAboutSettings = Notification.Name("FileveroShowAboutSettings")
}

/// Builds macOS application menu bar items and the interactive status bar menu.
extension AppDelegate {
    private static let recentFilesMenuID = NSUserInterfaceItemIdentifier("FileveroRecentFiles")
    private static let maximumRecentFiles = 10

    public func buildMenus() -> (main: NSMenu, app: NSMenu, status: NSMenu) {
        let mainMenu = NSMenu()
        let app = NSMenu(title: "Filevero")
        app.items = [
            makeMenuItem("About Filevero", "info.circle", #selector(showAbout)),
            .separator(),
            makeMenuItem("Settings…", "gearshape", #selector(showSettings), ","),
            makeMenuItem("Check for Updates…", "arrow.triangle.2.circlepath", #selector(checkForUpdates), "u"),
            makeMenuItem("Update Connection…", "link.badge.plus", #selector(showUpdateConnection)),
            .separator(),
            makeMenuItem("Quit Filevero", "power", #selector(quit), "q"),
        ]

        let file = NSMenu(title: "File")
        file.items = [
            makeMenuItem("Choose Files…", "plus.rectangle.on.folder", #selector(chooseFiles), "o"),
            makeMenuItem("Download Link…", "link", #selector(showDownloadLink), "d", [.control, .shift]),
        ]

        let edit = NSMenu(title: "Edit")
        for (title, key, selector) in [
            ("Undo", "z", "undo:"),
            ("Redo", "Z", "redo:"),
            ("Cut", "x", "cut:"),
            ("Copy", "c", "copy:"),
            ("Paste", "v", "paste:"),
            ("Select All", "a", "selectAll:"),
        ] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }

        let view = NSMenu(title: "View")
        view.items = [
            makeMenuItem("Home", "rectangle.split.3x1", #selector(showHome), "1"),
            makeMenuItem("Library", "tray.full", #selector(showLibrary), "2"),
            makeMenuItem("Find in Library…", "magnifyingglass", #selector(findInLibrary), "f"),
            .separator(),
            makeSubmenuItem("Theme", "paintpalette", createThemeSubmenu()),
            makeSubmenuItem("Appearance", "circle.lefthalf.filled", createAppearanceSubmenu()),
        ]

        let window = NSMenu(title: "Window")
        window.items = [
            makeMenuItem("Close Window", "xmark.square", #selector(NSWindow.performClose(_:)), "w", target: false),
            makeMenuItem("Minimize", "minus.square", #selector(NSWindow.performMiniaturize(_:)), "m", target: false),
            makeMenuItem("Zoom", "plus.square", #selector(NSWindow.performZoom(_:)), target: false),
        ]

        let help = NSMenu(title: "Help")
        help.items = [
            makeMenuItem("Welcome…", "hand.wave", #selector(showWelcome))
        ]

        for menu in [app, file, edit, view, window, help] {
            let container = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            container.submenu = menu
            mainMenu.addItem(container)
        }

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = window
        NSApp.helpMenu = help

        let recent = NSMenu(title: "Recent Files")
        recent.identifier = Self.recentFilesMenuID
        recent.delegate = self

        let status = NSMenu()
        status.items = [
            makeMenuItem("Filevero", "house", #selector(showHome)),
            .separator(),
            makeMenuItem("Choose Files…", "plus.rectangle.on.folder", #selector(chooseFiles)),
            makeMenuItem("Download Link…", "link", #selector(showDownloadLink)),
            .separator(),
            makeMenuItem("Enable Filevero", "power.circle", #selector(toggleEnabled)),
            makeSubmenuItem("Recent Files", "clock", recent),
            makeSubmenuItem("Theme", "paintpalette", createThemeSubmenu()),
            .separator(),
            makeMenuItem("Settings…", "gearshape", #selector(showSettings)),
            makeMenuItem("Check for Updates…", "arrow.triangle.2.circlepath", #selector(checkForUpdates)),
            makeMenuItem("Update Connection…", "link.badge.plus", #selector(showUpdateConnection)),
            .separator(),
            makeMenuItem("Quit Filevero", "power", #selector(quit), "q"),
        ]

        return (mainMenu, app, status)
    }

    private func makeMenuItem(
        _ title: String,
        _ symbol: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: Bool = true
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if target { menuItem.target = self }
        return menuItem
    }

    private func makeSubmenuItem(_ title: String, _ symbol: String, _ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menuItem.submenu = menu
        return menuItem
    }

    private func createThemeSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Theme")
        menu.delegate = self
        for theme in ColorTheme.allCases {
            let entry = NSMenuItem(title: theme.title, action: #selector(setTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = theme.rawValue
            entry.image = Self.renderThemeColorCircle(theme)
            menu.addItem(entry)
        }
        return menu
    }

    private func createAppearanceSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Appearance")
        menu.delegate = self
        for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let entry = NSMenuItem(title: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = value
            menu.addItem(entry)
        }
        return menu
    }

    private static func renderThemeColorCircle(_ theme: ColorTheme) -> NSImage {
        let (start, end) = ThemeTokenPalette.accentDuo(theme)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSGradient(starting: start, ending: end)?.draw(
                in: NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)),
                angle: -45
            )
            return true
        }
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String {
            UserDefaults.standard.set(value, forKey: "colorTheme")
        }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "appAppearance")
        FileveroAppearance.apply(value)
    }

    @objc func showAbout() {
        presentSettings(section: .about)
    }

    @objc func revealRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == Self.recentFilesMenuID {
            populateRecentItems(menu)
            return
        }
        let currentThemeSlug = ThemeTokenPalette.currentTheme.rawValue
        let currentAppearance = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
        for entry in menu.items {
            if entry.action == #selector(toggleEnabled) {
                entry.state = UserDefaults.standard.bool(forKey: "enabled") ? .on : .off
            }
            if entry.action == #selector(setTheme(_:)) {
                entry.state = entry.representedObject as? String == currentThemeSlug ? .on : .off
            }
            if entry.action == #selector(setAppearance(_:)) {
                entry.state = entry.representedObject as? String == currentAppearance ? .on : .off
            }
        }
    }

    private func populateRecentItems(_ menu: NSMenu) {
        menu.removeAllItems()
        var uniqueTracker = Set<String>()
        let recentPaths = state.history.flatMap(\.outputs).filter {
            uniqueTracker.insert($0).inserted && FileManager.default.fileExists(atPath: $0)
        }.prefix(Self.maximumRecentFiles)

        guard !recentPaths.isEmpty else {
            let emptyNotice = NSMenuItem(title: L10n.text("No recent files"), action: nil, keyEquivalent: "")
            emptyNotice.isEnabled = false
            menu.addItem(emptyNotice)
            return
        }

        for path in recentPaths {
            let entry = NSMenuItem(
                title: (path as NSString).lastPathComponent,
                action: #selector(revealRecentFile(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = path
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
        }
    }
}

