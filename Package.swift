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
        // The broker's XPC protocol keeps its own folder so the broker executable can compile it too.
        // Its Objective-C name is part of the wire contract and must not change.
        .target(
            name: "FileveroUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources",
            exclude: ["FileveroApp", "FileveroCore", "FileveroCLI", "UpdateCredentialBroker"],
            sources: ["FileveroUpdates", "FileveroBrokerProtocol/UpdateCredentialBrokerProtocol.swift"]),
        .executableTarget(
            name: "FileveroApp", dependencies: ["FileveroCore", "FileveroUpdates"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "FileveroCLI", dependencies: ["FileveroCore"]),
        .testTarget(name: "FileveroCoreTests", dependencies: ["FileveroCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FileveroUpdatesTests", dependencies: ["FileveroUpdates"]),
    ],
    swiftLanguageModes: [.v5]
)
