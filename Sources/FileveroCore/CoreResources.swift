import Foundation

/// Locates FileveroCore's JSON resources inside a packaged app.
///
/// Older SwiftPM toolchains (Swift 6.2, used by the macOS 26 release runner) generate a `Bundle.module` that looks
/// only beside the .app and in the builder's `.build` folder, and traps when neither exists. Code signing requires
/// the resource bundle to live in Contents/Resources, so look there first and keep `Bundle.module` for `swift run`
/// and tests.
enum CoreResources {
    static let bundleName = "Filevero_FileveroCore.bundle"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle(in: Bundle.main.resourceURL)?.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    static func bundle(in resources: URL?) -> Bundle? {
        resources.flatMap { Bundle(url: $0.appendingPathComponent(bundleName, isDirectory: true)) }
    }
}
