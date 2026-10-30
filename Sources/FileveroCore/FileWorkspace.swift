import Foundation

/// Filesystem management utilities for temporary workspaces, collision-safe destination naming,
/// size-preservation guards, and output integrity checks.
public enum FileWorkspace {
    
    /// Ensures that re-encoding an already optimized file does not increase its disk footprint
    /// or degrade quality when the output format and geometry remain identical.
    public static func retainSmallerOriginal(_ input: URL, output: URL, target: Int64?) throws {
        guard input.pathExtension.lowercased() == output.pathExtension.lowercased() else { return }
        
        let fileManager = FileManager.default
        let sourceURL = input.resolvingSymlinksInPath()
        let sourceAttrs = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let originalBytes = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        
        let outputAttrs = try fileManager.attributesOfItem(atPath: output.path)
        let encodedBytes = (outputAttrs[.size] as? NSNumber)?.int64Value ?? 0
        
        guard originalBytes > 0, encodedBytes > originalBytes, target == nil || originalBytes <= target! else {
            return
        }
        
        try fileManager.removeItem(at: output)
        try fileManager.copyItem(at: sourceURL, to: output)
    }
    
    /// Generates a guaranteed non-colliding destination URL in the target directory by appending
    /// a numeric increment when a file with the requested name already exists.
    public static func unique(
        for input: URL,
        extension ext: String,
        suffix: String = "",
        directory: URL? = nil
    ) -> URL {
        let parentDir = directory ?? input.deletingLastPathComponent()
        let baseStem = input.deletingPathExtension().lastPathComponent + suffix
        let normalizedExtension = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        var targetURL = parentDir.appendingPathComponent(baseStem).appendingPathExtension(normalizedExtension)
        var counter = 2
        
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: targetURL.path) {
            targetURL = parentDir
                .appendingPathComponent("\(baseStem) \(counter)")
                .appendingPathExtension(normalizedExtension)
            counter += 1
        }
        
        return targetURL
    }
    
    /// Creates a dedicated, sandboxed temporary folder for an export or processing session.
    public static func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filevero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    
    /// Validates that an array of output URLs was produced and that each artifact is non-empty.
    public static func validate(_ urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw FileveroError.failed("No output was produced.")
        }
        
        for fileURL in urls {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard resourceValues.isDirectory == true || (resourceValues.fileSize ?? 0) > 0 else {
                throw FileveroError.failed("An empty output was produced: \(fileURL.lastPathComponent)")
            }
        }
    }
}

public typealias OutputFiles = FileWorkspace

