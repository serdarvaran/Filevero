import Foundation

/// Atomic file relocation descriptor representing a source URL and intended destination URL.
public struct FileMove: Codable, Sendable, Equatable {
    public let source: URL
    public let destination: URL
    
    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// Ledger of applied filesystem changes capturing moved items and newly created directory trees,
/// allowing comprehensive, exact reversal (undo).
public struct AppliedMoves: Codable, Sendable, Equatable {
    public let moves: [FileMove]
    /// Folders created by the execution plan; removed during undo if they become empty.
    public let createdFolders: [URL]
    public let title: String
    public let date: Date
    
    public init(moves: [FileMove], createdFolders: [URL], title: String, date: Date) {
        self.moves = moves
        self.createdFolders = createdFolders
        self.title = title
        self.date = date
    }
}

/// Transactional engine for renaming and relocating existing user files.
/// Guarantees all-or-nothing execution: any mid-operation failure restores previously relocated files to their origins.
public enum FileRelocationEngine {
    
    @discardableResult
    public static func apply(_ plan: [FileMove], title: String) throws -> AppliedMoves {
        let activeMoves = plan.filter { $0.source.standardizedFileURL != $0.destination.standardizedFileURL }
        guard !activeMoves.isEmpty else {
            throw FileveroError.invalidInput("Nothing would change.")
        }
        
        try validate(activeMoves, checkingNames: true)
        let fileManager = FileManager.default
        var createdDirectories: [URL] = []
        
        do {
            let uniqueDestDirs = Set(activeMoves.map { $0.destination.deletingLastPathComponent().standardizedFileURL })
                .sorted(by: { $0.path.count < $1.path.count })
                
            for targetFolder in uniqueDestDirs {
                var missingHierarchy: [URL] = []
                var current = targetFolder
                while !fileManager.fileExists(atPath: current.path) {
                    missingHierarchy.insert(current, at: 0)
                    current = current.deletingLastPathComponent()
                }
                for dir in missingHierarchy {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
                    createdDirectories.append(dir)
                }
            }
            try executeMoves(activeMoves)
        } catch {
            pruneEmptyDirectories(createdDirectories)
            throw error
        }
        
        return AppliedMoves(moves: activeMoves, createdFolders: createdDirectories, title: title, date: Date())
    }

    public static func undo(_ applied: AppliedMoves) throws {
        let fileManager = FileManager.default
        for move in applied.moves {
            guard fileManager.fileExists(atPath: move.destination.path) else {
                throw FileveroError.failed(
                    "\(move.destination.lastPathComponent) was moved or deleted, so this change cannot be undone."
                )
            }
        }
        
        let reversedPlan = applied.moves.map { FileMove(source: $0.destination, destination: $0.source) }
        try validate(reversedPlan, checkingNames: false)
        try executeMoves(reversedPlan)
        pruneEmptyDirectories(applied.createdFolders)
    }

    private static func executeMoves(_ moves: [FileMove]) throws {
        let fileManager = FileManager.default
        let sourceKeys = Set(moves.map { caseInsensitiveKey($0.source) })
        
        // Staged moves handle in-place swap collisions or letter-case changes through a temporary scratch name
        let stagedMoves = moves.filter { sourceKeys.contains(caseInsensitiveKey($0.destination)) }
        let directMoves = moves.filter { !sourceKeys.contains(caseInsensitiveKey($0.destination)) }
        
        var parkedItems: [(temporary: URL, move: FileMove)] = []
        var completedMoves: [FileMove] = []
        
        do {
            for move in directMoves {
                guard !fileManager.fileExists(atPath: move.destination.path) else {
                    throw FileveroError.failed("\(move.destination.lastPathComponent) already exists.")
                }
                try fileManager.moveItem(at: move.source, to: move.destination)
                completedMoves.append(move)
            }
            
            for move in stagedMoves {
                let tempName = ".filevero-move-\(UUID().uuidString)"
                let temporaryURL = move.source.deletingLastPathComponent().appendingPathComponent(tempName)
                try fileManager.moveItem(at: move.source, to: temporaryURL)
                parkedItems.append((temporaryURL, move))
            }
            
            for item in parkedItems {
                guard !fileManager.fileExists(atPath: item.move.destination.path) else {
                    throw FileveroError.failed("\(item.move.destination.lastPathComponent) already exists.")
                }
                try fileManager.moveItem(at: item.temporary, to: item.move.destination)
                completedMoves.append(item.move)
            }
        } catch {
            var strandedPaths: [String] = []
            
            for move in completedMoves.reversed() {
                do {
                    try fileManager.moveItem(at: move.destination, to: move.source)
                } catch {
                    strandedPaths.append(move.destination.path)
                }
            }
            
            for item in parkedItems where !completedMoves.contains(item.move) {
                do {
                    try fileManager.moveItem(at: item.temporary, to: item.move.source)
                } catch {
                    strandedPaths.append(item.temporary.path)
                }
            }
            
            guard strandedPaths.isEmpty else {
                throw FileveroError.failed(
                    "\(error.localizedDescription) Some files could not be put back and are now at: \(strandedPaths.joined(separator: ", "))"
                )
            }
            throw error
        }
    }

    private static func validate(_ moves: [FileMove], checkingNames: Bool) throws {
        let fileManager = FileManager.default
        let sourceKeys = Set(moves.map { caseInsensitiveKey($0.source) })
        var targetKeys = Set<String>()
        
        for move in moves {
            guard fileManager.fileExists(atPath: move.source.path) else {
                throw FileveroError.invalidInput("\(move.source.lastPathComponent) no longer exists.")
            }
            
            let name = move.destination.lastPathComponent
            if checkingNames, name != move.source.lastPathComponent {
                guard !name.isEmpty,
                      !name.hasPrefix("."),
                      name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil,
                      name.utf8.count <= 255
                else {
                    throw FileveroError.invalidInput("“\(name)” is not a valid file name.")
                }
            }
            
            guard targetKeys.insert(caseInsensitiveKey(move.destination)).inserted else {
                throw FileveroError.invalidInput("Two files would get the name “\(name)”.")
            }
            
            if fileManager.fileExists(atPath: move.destination.path), !sourceKeys.contains(caseInsensitiveKey(move.destination)) {
                throw FileveroError.invalidInput("“\(name)” already exists.")
            }
        }
    }

    private static func caseInsensitiveKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func pruneEmptyDirectories(_ folders: [URL]) {
        let fileManager = FileManager.default
        for folder in folders.reversed() {
            if (try? fileManager.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? fileManager.removeItem(at: folder)
            }
        }
    }
}

public typealias FileMoveEngine = FileRelocationEngine

