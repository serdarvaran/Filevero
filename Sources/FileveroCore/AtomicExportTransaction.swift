import Foundation

/// Coordinates safe, atomic staging and multi-file publication transactions.
/// Ensures that cancelled or interrupted processing jobs never pollute target directories with partial artifacts,
/// and that published files are safely committed via same-volume atomic relocations.
public final class AtomicExportTransaction {
    
    public final class StagingArea {
        public let directory: URL
        public let destination: URL
        public var outputs: [URL] = []
        
        public init(directory: URL, destination: URL) {
            self.directory = directory
            self.destination = destination
        }
    }

    private let fileManager = FileManager.default
    private var stagingAreas: [StagingArea] = []

    public init() {}

    /// Prepares an isolated staging scratchpad alongside the specified target directory.
    public func makeArea(destination: URL) throws -> StagingArea {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let scratchDirectory = destination.appendingPathComponent(
            ".Filevero-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let area = StagingArea(directory: scratchDirectory, destination: destination)
        stagingAreas.append(area)
        return area
    }

    /// Verifies that all produced outputs reside safely within the designated staging scratchpad.
    public func record(_ outputs: [URL], in area: StagingArea) throws {
        try FileWorkspace.validate(outputs)
        let normalizedPrefix = area.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        
        guard outputs.allSatisfy({ $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(normalizedPrefix) }) else {
            throw FileveroError.failed("An export could not be staged safely. Your originals were not changed.")
        }
        area.outputs = outputs
    }

    /// Commits all staged outputs to their target destination folders using safe collision-avoidance naming.
    /// In case of error or cancellation midway, all previously published outputs in this transaction are cleaned up.
    public func publish(
        token: CancellationToken,
        naming: OutputNameTemplate? = nil,
        sequence: OutputSequence? = nil,
        date: Date = Date()
    ) throws -> [URL] {
        var committedDestinations: [URL] = []
        var finalPublishedOutputs: [URL] = []
        var transactionSucceeded = false
        
        defer {
            if !transactionSucceeded {
                for publishedURL in committedDestinations.reversed() {
                    try? fileManager.removeItem(at: publishedURL)
                }
            }
        }
        
        let preparedAreas = try stagingAreas.map { area -> (area: StagingArea, relativeOutputs: [[String]], children: [URL]) in
            try token.check()
            let normalizedPrefix = area.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let relativeOutputs = area.outputs.map { output in
                let fullPath = output.standardizedFileURL.resolvingSymlinksInPath().path
                return String(fullPath.dropFirst(normalizedPrefix.count))
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
            }
            
            let rootNames = Set(relativeOutputs.compactMap(\.first))
            let children = try fileManager.contentsOfDirectory(
                at: area.directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            .filter { rootNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            guard Set(children.map(\.lastPathComponent)) == rootNames else {
                throw FileveroError.failed("A completed export could not be located.")
            }
            return (area, relativeOutputs, children)
        }
        
        let totalRoots = preparedAreas.reduce(0) { $0 + $1.children.count }
        let overallCount = max(totalRoots, sequence?.total ?? 0)
        var sequentialIndex = (sequence?.index ?? 1) - 1
        
        for (area, relativeOutputs, children) in preparedAreas {
            var destinationMapping: [String: URL] = [:]
            
            for child in children {
                try token.check()
                sequentialIndex += 1
                
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let resolvedName: String
                if let namingTemplate = naming {
                    resolvedName = try namingTemplate.name(
                        for: child.lastPathComponent,
                        index: sequentialIndex,
                        total: overallCount,
                        date: date,
                        isDirectory: isDirectory
                    )
                } else {
                    resolvedName = child.lastPathComponent
                }
                
                let finalDestination = makeUniqueDestination(
                    named: resolvedName,
                    isDirectory: isDirectory,
                    in: area.destination
                )
                
                try fileManager.moveItem(at: child, to: finalDestination)
                committedDestinations.append(finalDestination)
                destinationMapping[child.lastPathComponent] = finalDestination
            }
            
            for pathComponents in relativeOutputs {
                guard let firstComponent = pathComponents.first,
                      let rootDestination = destinationMapping[firstComponent]
                else {
                    throw FileveroError.failed("A completed export could not be located.")
                }
                
                let assembledURL = pathComponents.dropFirst().reduce(rootDestination) { acc, next in
                    acc.appendingPathComponent(String(next))
                }
                finalPublishedOutputs.append(assembledURL)
            }
        }
        
        try token.check()
        try FileWorkspace.validate(finalPublishedOutputs)
        transactionSucceeded = true
        return finalPublishedOutputs
    }

    private func makeUniqueDestination(named name: String, isDirectory: Bool, in parentDir: URL) -> URL {
        if !isDirectory {
            let candidate = parentDir.appendingPathComponent(name)
            return FileWorkspace.unique(for: candidate, extension: candidate.pathExtension, directory: parentDir)
        }
        
        var targetFolder = parentDir.appendingPathComponent(name, isDirectory: true)
        var increment = 2
        while fileManager.fileExists(atPath: targetFolder.path) {
            targetFolder = parentDir.appendingPathComponent("\(name) \(increment)", isDirectory: true)
            increment += 1
        }
        return targetFolder
    }

    /// Deletes all intermediate scratch directories created by this transaction.
    public func cleanUp() {
        for area in stagingAreas {
            try? fileManager.removeItem(at: area.directory)
        }
    }
}

public typealias ExportTransaction = AtomicExportTransaction

