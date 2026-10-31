import Foundation

/// Finder Services and the login item remember the app's path, so Filevero should run from an Applications folder
/// rather than from Downloads or a mounted disk image.
public enum ApplicationInstallLocation {
    /// The Applications folder to copy the running bundle into, or nil when it is already installed or not an app bundle.
    public static func installFolder(for bundle: URL, home: URL, systemApplicationsWritable: Bool) -> URL? {
        guard bundle.pathExtension == "app" else { return nil }
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = home.appendingPathComponent("Applications", isDirectory: true)
        let path = bundle.standardizedFileURL.path
        if [system, user].contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) { return nil }
        return systemApplicationsWritable ? system : user
    }

    /// Gatekeeper runs a quarantined app that the user has not moved from a random read-only copy of its folder.
    public static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.path.contains("/AppTranslocation/")
    }
}
