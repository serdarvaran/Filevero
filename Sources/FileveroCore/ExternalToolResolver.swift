import Foundation

/// Locates and validates external command-line binaries required for specialized operations
/// (e.g. ffmpeg, ffprobe, exiftool, libreoffice / soffice).
public enum ExternalToolResolver {
    
    /// Resolves the file URL of an executable tool by inspecting custom environment variables,
    /// application bundle resources, external tool setup paths, and system standard directories.
    public static func executable(_ name: String) throws -> URL {
        let fileManager = FileManager.default
        let envKey = "FILEVERO_" + name.uppercased()
        var searchPaths: [String] = []
        
        // 1. Explicit environment variable override
        if let envOverride = ProcessInfo.processInfo.environment[envKey] {
            searchPaths.append(envOverride)
        }
        
        // 2. Embedded application bundle resources
        if let resourceURL = Bundle.main.resourceURL {
            searchPaths.append(resourceURL.appendingPathComponent("Tools/\(name)").path)
            if name == "exiftool" {
                searchPaths.append(resourceURL.appendingPathComponent("Tools/ExifTool/exiftool").path)
            }
            if name == "soffice" {
                searchPaths.append(resourceURL.appendingPathComponent("Tools/LibreOffice.app/Contents/MacOS/soffice").path)
            }
        }
        
        // 3. User-downloaded or dynamic tool setup directory
        if let externalExecutable = ExternalToolSetup.executable(name) {
            searchPaths.append(externalExecutable.path)
        }
        
        // 4. Debug workspace paths
        #if DEBUG
        let workspaceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        searchPaths.append(workspaceRoot.appendingPathComponent("Tools/\(name)").path)
        if name == "exiftool" {
            searchPaths.append(workspaceRoot.appendingPathComponent("Tools/ExifTool/exiftool").path)
        }
        if name == "soffice" {
            searchPaths.append(workspaceRoot.appendingPathComponent("Tools/LibreOffice.app/Contents/MacOS/soffice").path)
        }
        #endif
        
        // 5. Standard macOS installation directories
        searchPaths += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        
        if name == "soffice" {
            searchPaths.append("/Applications/LibreOffice.app/Contents/MacOS/soffice")
        }
        
        // Verify executable presence and valid file attributes
        guard let resolvedPath = searchPaths.first(where: { path in
            let candidateURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(atPath: candidateURL.path) else { return false }
            let resourceValues = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return resourceValues?.isRegularFile == true && (resourceValues?.fileSize ?? 0) > 0
        }) else {
            throw FileveroError.missingDependency(name)
        }
        
        return URL(fileURLWithPath: resolvedPath)
    }
}

public typealias Dependencies = ExternalToolResolver

