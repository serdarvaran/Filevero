import CryptoKit
import Foundation

public enum OrganizeMode: String, Codable, CaseIterable, Sendable {
    case month, year, type
    
    public var title: String {
        switch self {
        case .month: return "By month"
        case .year: return "By year"
        case .type: return "By kind"
        }
    }
}

/// Automates structural file organization by partitioning files into thematic or temporal subdirectories.
public enum DirectoryOrganizerService {
    
    /// Generates a relocation plan moving each file into a subfolder partitioned by kind, month, or year.
    public static func plan(
        _ urls: [URL],
        mode: OrganizeMode,
        dateSource: FileDateSource = .captured,
        language: String = "en"
    ) -> [FileMove] {
        urls.map { fileURL in
            let folderName: String
            switch mode {
            case .type:
                folderName = LocalizationEngine.text(FileCategory.detect(fileURL).title, language: language)
            case .month, .year:
                let components = Calendar(identifier: .gregorian).dateComponents(
                    [.year, .month],
                    from: dateSource.date(of: fileURL)
                )
                folderName = mode == .year
                    ? String(format: "%04d", components.year ?? 0)
                    : String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            }
            
            let destinationURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(fileURL.lastPathComponent)
                
            return FileMove(source: fileURL, destination: destinationURL)
        }
    }
}

public typealias FileOrganizer = DirectoryOrganizerService

/// Traverses directories, expanding folder hierarchies into flat, ordered lists of regular files.
public enum FolderInspector {
    public static let maximumFiles = 10_000

    public static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Recursively or shallowly traverses input URLs, collecting individual regular files and bundle packages.
    public static func files(in urls: [URL], recursive: Bool) throws -> [URL] {
        var accumulatedFiles: [URL] = []
        var visitedPaths = Set<String>()
        
        func markVisited(_ url: URL) -> Bool {
            visitedPaths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
        
        for rootURL in urls {
            guard isFolder(rootURL) else {
                if markVisited(rootURL) { accumulatedFiles.append(rootURL) }
                continue
            }
            
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            var traversalOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !recursive {
                traversalOptions.insert(.skipsSubdirectoryDescendants)
            }
            
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: resourceKeys,
                options: traversalOptions
            ) else {
                throw FileveroError.failed("\(rootURL.lastPathComponent) could not be read.")
            }
            
            var localBatch: [URL] = []
            for case let itemURL as URL in enumerator where !isFolder(itemURL) && markVisited(itemURL) {
                localBatch.append(itemURL)
                guard accumulatedFiles.count + localBatch.count <= maximumFiles else {
                    throw FileveroError.invalidInput(
                        "These folders contain more than \(maximumFiles) files. Choose a smaller folder."
                    )
                }
            }
            accumulatedFiles += localBatch.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return accumulatedFiles
    }
}

public typealias FolderContents = FolderInspector

/// Locates identical files across directories using multi-stage size clustering and streaming SHA-256 digests.
public enum DuplicateFinder {
    
    /// Groups files with identical byte content, sorting each cluster chronologically (oldest file first).
    public static func groups(
        in urls: [URL],
        token: CancellationToken = .init(),
        progress: ProgressHandler = { _, _ in }
    ) throws -> [[URL]] {
        let allFiles = try FolderInspector.files(in: urls, recursive: true)
        var sizeBuckets: [Int: [URL]] = [:]
        var uniqueFileIdentities = Set<String>()
        
        for file in allFiles {
            let resourceValues = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey])
            guard resourceValues.isRegularFile == true, let size = resourceValues.fileSize, size > 0 else {
                continue
            }
            
            // Hard links share the exact same filesystem inode; ignore duplicates pointing to the identical storage block.
            if let identifier = resourceValues.fileResourceIdentifier.map({ String(describing: $0) }),
               !uniqueFileIdentities.insert(identifier).inserted {
                continue
            }
            sizeBuckets[size, default: []].append(file)
        }
        
        let collisionCandidates = sizeBuckets.values.filter { $0.count > 1 }
        let totalCandidates = collisionCandidates.reduce(0) { $0 + $1.count }
        var processedCount = 0
        var matchedGroups: [[URL]] = []
        
        for bucket in collisionCandidates {
            var hashBuckets: [Data: [URL]] = [:]
            for candidateFile in bucket {
                try token.check()
                let digestData = try computeDigest(candidateFile, token: token)
                hashBuckets[digestData, default: []].append(candidateFile)
                processedCount += 1
                progress(Double(processedCount) / Double(max(1, totalCandidates)), "Comparing \(processedCount) of \(totalCandidates) files")
            }
            matchedGroups += hashBuckets.values
                .filter { $0.count > 1 }
                .map { $0.sorted { resolveCreationDate($0) < resolveCreationDate($1) } }
        }
        
        return matchedGroups.sorted { $0[0].path.localizedStandardCompare($1[0].path) == .orderedAscending }
    }

    private static func computeDigest(_ url: URL, token: CancellationToken) throws -> Data {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        while let buffer = try fileHandle.read(upToCount: 1 << 20), !buffer.isEmpty {
            try token.check()
            hasher.update(data: buffer)
        }
        return Data(hasher.finalize())
    }

    private static func resolveCreationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
    }
}

/// Convenience bundler archiving multiple selected files or directories into one archive (ZIP unless chosen otherwise).
public enum SelectionArchive {
    
    public static func create(
        _ inputs: [URL],
        options: OperationOptions,
        token: CancellationToken
    ) throws -> [URL] {
        guard let firstURL = inputs.first else {
            throw FileveroError.invalidInput("Choose files to archive.")
        }
        
        let fileNames = inputs.map(\.lastPathComponent)
        guard Set(fileNames.map { $0.lowercased() }).count == fileNames.count else {
            throw FileveroError.invalidInput("Two selected items have the same name. Rename one before archiving.")
        }
        
        let destinationDir = options.outputDirectory ?? firstURL.deletingLastPathComponent()
        let stagingFolder = destinationDir.appendingPathComponent(".filevero-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingFolder) }
        
        for inputURL in inputs {
            try token.check()
            try FileManager.default.copyItem(
                at: inputURL,
                to: stagingFolder.appendingPathComponent(inputURL.lastPathComponent)
            )
        }
        
        let format = options.archiveFormat ?? "zip"
        guard ArchiveCodec.writableFormats.contains(format) else {
            throw FileveroError.unsupported("Cannot create \(format.uppercased()) archives.")
        }
        let baseArchiveName = inputs.count == 1 ? firstURL.lastPathComponent : "Archive"
        let outputURL = FileWorkspace.unique(
            for: destinationDir.appendingPathComponent(baseArchiveName + ".zip"),
            extension: ArchiveCodec.fileExtension(for: format),
            directory: options.outputDirectory
        )
        
        try ArchiveCodec.create(from: stagingFolder, at: outputURL, format: format, token: token)
        return [outputURL]
    }
}

