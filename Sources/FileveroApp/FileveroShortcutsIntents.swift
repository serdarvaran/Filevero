import Foundation
import FileveroCore

#if canImport(AppIntents)
import AppIntents

/// macOS Shortcuts action to convert files using Filevero's offline engine.
public struct FileveroConvertIntent: AppIntent {
    public static var title: LocalizedStringResource = "Convert File with Filevero"
    public static var description = IntentDescription("Converts a file to a selected target format using Filevero's local engine.")

    @Parameter(title: "Input File", description: "The file to convert")
    public var file: IntentFile?

    @Parameter(title: "Target Format", description: "Target extension (e.g. png, jpg, webp, pdf, mp4, mp3)", default: "png")
    public var targetFormat: String

    public init() {
        self.targetFormat = "png"
    }

    public init(file: IntentFile, targetFormat: String) {
        self.file = file
        self.targetFormat = targetFormat
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let file, let sourceURL = file.fileURL else {
            throw FileveroError.invalidInput("A valid file is required.")
        }
        let target = targetFormat.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var options = OperationOptions()
        options.outputDirectory = sourceURL.deletingLastPathComponent()
        let request = ConversionRequest(
            inputs: [sourceURL],
            operation: .convert(target),
            options: options
        )
        let outputs = try RoutingConversionEngine.run(request)
        guard let firstOutput = outputs.first else {
            throw FileveroError.failed("Conversion produced no output file.")
        }
        return .result(value: IntentFile(fileURL: firstOutput))
    }
}

/// macOS Shortcuts action to remove background using Apple Vision subject lifting.
public struct FileveroRemoveBackgroundIntent: AppIntent {
    public static var title: LocalizedStringResource = "Remove Background with Filevero"
    public static var description = IntentDescription("Removes the background from an image using Apple Vision on-device machine learning.")

    @Parameter(title: "Image File", description: "The image to remove background from")
    public var image: IntentFile?

    public init() {}

    public init(image: IntentFile) {
        self.image = image
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let image, let sourceURL = image.fileURL else {
            throw FileveroError.invalidInput("A valid image file is required.")
        }
        var options = OperationOptions()
        options.outputDirectory = sourceURL.deletingLastPathComponent()
        let request = ConversionRequest(
            inputs: [sourceURL],
            operation: .tool(.removeBackground),
            options: options
        )
        let outputs = try RoutingConversionEngine.run(request)
        guard let firstOutput = outputs.first else {
            throw FileveroError.failed("Background removal produced no output.")
        }
        return .result(value: IntentFile(fileURL: firstOutput))
    }
}

/// macOS Shortcuts action to compress files locally.
public struct FileveroCompressIntent: AppIntent {
    public static var title: LocalizedStringResource = "Compress File with Filevero"
    public static var description = IntentDescription("Compresses an image, video, audio, or PDF file to reduce size locally.")

    @Parameter(title: "Input File", description: "The media file or document to compress")
    public var file: IntentFile?

    public init() {}

    public init(file: IntentFile) {
        self.file = file
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let file, let sourceURL = file.fileURL else {
            throw FileveroError.invalidInput("A valid media file or document is required.")
        }
        var options = OperationOptions()
        options.outputDirectory = sourceURL.deletingLastPathComponent()
        let request = ConversionRequest(
            inputs: [sourceURL],
            operation: .tool(.compress),
            options: options
        )
        let outputs = try RoutingConversionEngine.run(request)
        guard let firstOutput = outputs.first else {
            throw FileveroError.failed("Compression produced no output.")
        }
        return .result(value: IntentFile(fileURL: firstOutput))
    }
}

/// Registers Apple Shortcuts phrases for Siri and the macOS Shortcuts app.
public struct FileveroShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FileveroConvertIntent(),
            phrases: [
                "Convert \(\.$file) with \(.applicationName)",
                "Convert with \(.applicationName)"
            ],
            shortTitle: "Convert File",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: FileveroRemoveBackgroundIntent(),
            phrases: [
                "Remove background from \(\.$image) with \(.applicationName)",
                "Remove background with \(.applicationName)"
            ],
            shortTitle: "Remove Background",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: FileveroCompressIntent(),
            phrases: [
                "Compress \(\.$file) with \(.applicationName)",
                "Compress file with \(.applicationName)"
            ],
            shortTitle: "Compress File",
            systemImageName: "arrow.down.right.and.arrow.up.left"
        )
    }
}

#endif
