import AppKit
import Darwin
import FileveroCore

/// Offers to copy a Filevero that runs from Downloads or a disk image into the Applications folder and reopen it there.
@MainActor
enum ApplicationsFolderMover {
    private static let suppressionKey = "moveToApplicationsSuppressed"

    /// Returns true when the installed copy is being opened and this process should quit.
    static func offerMoveIfNeeded() -> Bool {
        let fileManager = FileManager.default
        let running = Bundle.main.bundleURL
        guard !UserDefaults.standard.bool(forKey: suppressionKey),
              let folder = ApplicationInstallLocation.installFolder(
                  for: running,
                  home: fileManager.homeDirectoryForCurrentUser,
                  systemApplicationsWritable: fileManager.isWritableFile(atPath: "/Applications")
              )
        else { return false }

        // The welcome screen, where the language is chosen, comes later; follow the system language until then.
        let language = UserDefaults.standard.string(forKey: "appLanguage")
            ?? (Locale.preferredLanguages.first?.hasPrefix("tr") == true ? "tr" : "en")
        let text = { (source: String) in L10n.text(source, language: language) }
        let alert = NSAlert()
        alert.messageText = text("Move Filevero to the Applications folder?")
        alert.informativeText = text(
            "Finder services and opening at login only keep working when Filevero runs from the Applications folder. Filevero copies itself there, removes this copy and opens again."
        )
        alert.addButton(withTitle: text("Move to Applications"))
        alert.addButton(withTitle: text("Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = text("Do not ask again")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressionKey) }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let source = originalLocation(of: running)
            let installed = try install(source, into: folder)
            removeOriginal(source)
            try reopen(installed)
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = text("Filevero could not be moved to the Applications folder")
            failure.informativeText = error.localizedDescription + "\n\n"
                + text("Quit Filevero and drag it to the Applications folder in Finder.")
            failure.addButton(withTitle: text("OK"))
            failure.runModal()
            return false
        }
    }

    private static func install(_ source: URL, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path),
           Bundle(url: destination)?.bundleIdentifier != Bundle.main.bundleIdentifier {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        // Copy beside the destination first so a failed copy never replaces a working installation.
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).app")
        do {
            try fileManager.copyItem(at: source, to: staging)
            try removeQuarantine(staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            if fileManager.fileExists(atPath: staging.path) { try? fileManager.removeItem(at: staging) }
            throw error
        }
        return destination
    }

    /// Gatekeeper already let the user open this copy. Keeping the quarantine flag on the installed copy would make
    /// macOS run it from a randomized read-only location again (App Translocation), where Services cannot register.
    private static func removeQuarantine(_ bundle: URL) throws {
        let attribute = "com.apple.quarantine"
        var paths = [bundle.path]
        if let contents = FileManager.default.enumerator(atPath: bundle.path) {
            paths += contents.compactMap { ($0 as? String).map { bundle.appendingPathComponent($0).path } }
        }
        for path in paths where removexattr(path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
        }
    }

    /// A translocated app runs from a temporary copy; this returns the downloaded original the user opened.
    private static func originalLocation(of bundle: URL) -> URL {
        guard ApplicationInstallLocation.isTranslocated(bundle),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return bundle }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        return originalPath(bundle as CFURL, nil).map { $0.takeRetainedValue() as URL } ?? bundle
    }

    /// Moves the downloaded copy to the Trash so only one Filevero remains. A disk image is read-only and is left as is.
    private static func removeOriginal(_ source: URL) {
        guard !ApplicationInstallLocation.isTranslocated(source),
              (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false
        else { return }
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
        } catch {
            // The installed copy already works; a second copy left in Downloads is harmless.
            NSLog("Filevero kept its original copy at %@: %@", source.path, error.localizedDescription)
        }
    }

    /// Opens the installed copy once this process has exited, so the two copies never run at the same time.
    private static func reopen(_ application: URL) throws {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), application.path
        ]
        try waiter.run()
    }
}
