import Foundation

/// Formats and resolves output file names from dynamic templates supporting placeholders:
/// - `{name}`: Base filename stem of the original asset
/// - `{n}`: Sequence number zero-padded according to the batch size
/// - `{date}`: Year-month-day formatted timestamp (YYYY-MM-DD)
public struct OutputNameFormatter: Sendable, Equatable {
    
    private enum Token: Sendable, Equatable {
        case literal(String)
        case stemName
        case sequenceNumber
        case isoDate
    }

    // APFS allows a maximum of 255 UTF-8 bytes per path component;
    // reserve margin for extension and collision suffix (e.g. " 2.png").
    private static let maximumComponentBytes = 240
    private let tokens: [Token]

    public init(_ pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FileveroError.invalidInput("Enter a name template.")
        }
        guard !pattern.hasPrefix(".") else {
            throw FileveroError.invalidInput("File names cannot start with a period.")
        }
        guard pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil else {
            throw FileveroError.invalidInput("File names cannot contain “/”, “:” or line breaks.")
        }
        
        var parsedTokens: [Token] = []
        var remainder = pattern[...]
        
        while let braceIndex = remainder.firstIndex(where: { $0 == "{" || $0 == "}" }) {
            if braceIndex > remainder.startIndex {
                parsedTokens.append(.literal(String(remainder[..<braceIndex])))
            }
            guard remainder[braceIndex] == "{",
                  let closeBraceIndex = remainder[braceIndex...].firstIndex(of: "}")
            else {
                throw Self.invalidTokenError
            }
            
            let placeholder = remainder[braceIndex...closeBraceIndex]
            switch placeholder {
            case "{name}": parsedTokens.append(.stemName)
            case "{n}": parsedTokens.append(.sequenceNumber)
            case "{date}": parsedTokens.append(.isoDate)
            default: throw Self.invalidTokenError
            }
            
            remainder = remainder[remainder.index(after: closeBraceIndex)...]
        }
        
        if !remainder.isEmpty {
            parsedTokens.append(.literal(String(remainder)))
        }
        
        let literalLength = parsedTokens.reduce(0) { total, token in
            if case .literal(let text) = token { return total + text.utf8.count }
            return total
        }
        
        guard literalLength <= Self.maximumComponentBytes else {
            throw FileveroError.invalidInput("The name template is too long.")
        }
        
        self.tokens = parsedTokens
    }

    private static let invalidTokenError = FileveroError.invalidInput("Use only {name}, {n} and {date} inside braces.")

    /// Generates the formatted file name for a source item at a 1-based `index` in a batch of size `total`.
    public func name(
        for original: String,
        index: Int,
        total: Int,
        date: Date,
        isDirectory: Bool = false
    ) throws -> String {
        let nsSource = original as NSString
        let fileExtension = isDirectory ? "" : nsSource.pathExtension
        let baseStem = fileExtension.isEmpty ? original : nsSource.deletingPathExtension
        
        let numberString = String(index)
        let totalDigits = String(max(total, index)).count
        let zeroPaddedNumber = String(repeating: "0", count: max(0, totalDigits - numberString.count)) + numberString
        
        let assembledBody = tokens.map { token -> String in
            switch token {
            case .literal(let text): return text
            case .stemName: return baseStem
            case .sequenceNumber: return zeroPaddedNumber
            case .isoDate: return Self.formatIsoDate(date)
            }
        }.joined()
        
        let finalCandidate = (fileExtension.isEmpty ? assembledBody : assembledBody + "." + fileExtension)
            .precomposedStringWithCanonicalMapping
            
        guard !finalCandidate.hasPrefix(".") else {
            throw FileveroError.invalidInput("File names cannot start with a period.")
        }
        guard finalCandidate.utf8.count <= Self.maximumComponentBytes else {
            throw FileveroError.invalidInput("The resulting file name is too long: \(finalCandidate)")
        }
        
        return finalCandidate
    }

    private static func formatIsoDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

public typealias OutputNameTemplate = OutputNameFormatter

/// Precomputes target destination file names for a prospective batch before execution,
/// predicting duplicate collisions and existing file name increments.
public struct OutputNamePreview: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case available
        /// A file with this name already exists in the destination; a numerical suffix is appended.
        case existing
        /// Another item in this batch has already claimed this name.
        case duplicate
    }
    
    public let input: URL
    public let name: String
    public let status: Status

    public static func preview(
        _ inputs: [URL],
        format: String,
        template: String?,
        outputDirectory: URL? = nil,
        date: Date = Date(),
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> [OutputNamePreview] {
        let formatter = try template.map(OutputNameFormatter.init)
        let normalizedExt = format.lowercased()
        var claimedNamesByDirectory: [String: Set<String>] = [:]
        
        return try inputs.enumerated().map { index, input in
            let targetDir = outputDirectory ?? input.deletingLastPathComponent()
            let category = FileCategory.detect(input)
            let isFolder = ["png", "jpg"].contains(normalizedExt) && ![.image, .video].contains(category)
            let baseStem = input.deletingPathExtension().lastPathComponent
            let engineNominalName = isFolder ? baseStem + " - Pages" : baseStem + "." + normalizedExt
            
            let evaluatedName = try formatter?.name(
                for: engineNominalName,
                index: index + 1,
                total: inputs.count,
                date: date,
                isDirectory: isFolder
            ) ?? engineNominalName
            
            var directoryClaims = claimedNamesByDirectory[targetDir.path, default: []]
            let stemWithoutExt = isFolder ? evaluatedName : (evaluatedName as NSString).deletingPathExtension
            let extensionWithDot = isFolder ? "" : "." + (evaluatedName as NSString).pathExtension
            
            var candidateName = evaluatedName
            var duplicateSuffix = 2
            var candidateStatus = Status.available
            
            while directoryClaims.contains(candidateName.lowercased()) || exists(targetDir.appendingPathComponent(candidateName)) {
                if candidateStatus == .available {
                    candidateStatus = directoryClaims.contains(candidateName.lowercased()) ? .duplicate : .existing
                }
                candidateName = "\(stemWithoutExt) \(duplicateSuffix)\(extensionWithDot)"
                duplicateSuffix += 1
            }
            
            directoryClaims.insert(candidateName.lowercased())
            claimedNamesByDirectory[targetDir.path] = directoryClaims
            
            return OutputNamePreview(input: input, name: candidateName, status: candidateStatus)
        }
    }
}

