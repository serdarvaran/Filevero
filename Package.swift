// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Filevero",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FileveroCore", targets: ["FileveroCore"]),
        .executable(name: "Filevero", targets: ["FileveroApp"]),
        .executable(name: "filevero-cli", targets: ["FileveroCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "FileveroCore", resources: [.copy("Resources")]),
        .target(name: "FileveroUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(
            name: "FileveroApp", dependencies: ["FileveroCore", "FileveroUpdates"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "FileveroCLI", dependencies: ["FileveroCore"]),
        .testTarget(name: "FileveroCoreTests", dependencies: ["FileveroCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FileveroUpdatesTests", dependencies: ["FileveroUpdates"]),
    ],
    swiftLanguageModes: [.v5]
)
