import Foundation
import ImageIO

public enum FileDateSource: String, Codable, CaseIterable, Sendable {
    case captured, modified, created, today

    public var title: String {
        switch self {
        case .captured: return "Date taken"
        case .modified: return "Date modified"
        case .created: return "Date created"
        case .today: return "Today"
        }
    }

    public func date(of url: URL, now: Date = Date()) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        switch self {
        case .today: return now
        case .created: return values?.creationDate ?? now
        case .modified: return values?.contentModificationDate ?? now
        case .captured: return Self.captureDate(url) ?? values?.contentModificationDate ?? now
        }
    }

    static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

public enum LetterCase: String, Codable, CaseIterable, Sendable {
    case keep, lower, upper, title

    public var title: String {
        switch self {
        case .keep: return "Keep"
        case .lower: return "lowercase"
        case .upper: return "UPPERCASE"
        case .title: return "Title Case"
        }
    }
}

public struct RenameOptions: Codable, Sendable, Equatable {
    public var template = "{name}"
    public var find = ""
    public var replace = ""
    public var letterCase: LetterCase = .keep
    public var startNumber = 1
    public var dateSource: FileDateSource = .captured

    public init() {}
}

public struct RenamePreviewRow: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case unchanged, ready
        case conflict(String)
    }
    public let source: URL
    public let name: String
    public let status: Status

    public init(source: URL, name: String, status: Status) {
        self.source = source
        self.name = name
        self.status = status
    }
}

/// Advanced batch file renaming, template substitution, pattern replacement, and conflict detection.
public enum BatchFileNamer {
    public static func preview(
        _ urls: [URL], options: RenameOptions, suggestions: [URL: String] = [:], now: Date = Date(),
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [RenamePreviewRow] {
        let template: OutputNameTemplate
        do { template = try OutputNameTemplate(options.template) } catch {
            return urls.map {
                RenamePreviewRow(source: $0, name: $0.lastPathComponent, status: .conflict(error.localizedDescription))
            }
        }
        let start = max(0, options.startNumber)
        var names: [String?] = []
        var errors: [String?] = []
        for (index, url) in urls.enumerated() {
            do {
                names.append(
                    try newName(
                        url, template: template, options: options, suggestion: suggestions[url], index: start + index,
                        total: start + urls.count - 1, now: now))
                errors.append(nil)
            } catch {
                names.append(nil)
                errors.append(error.localizedDescription)
            }
        }
        let sources = Set(urls.map(key))
        var counts: [String: Int] = [:]
        for (url, name) in zip(urls, names) {
            if let name { counts[key(url.deletingLastPathComponent().appendingPathComponent(name)), default: 0] += 1 }
        }
        return urls.indices.map { index in
            let url = urls[index]
            guard let name = names[index] else {
                return RenamePreviewRow(
                    source: url, name: url.lastPathComponent, status: .conflict(errors[index] ?? ""))
            }
            if name == url.lastPathComponent { return RenamePreviewRow(source: url, name: name, status: .unchanged) }
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if counts[key(target), default: 0] > 1 {
                return RenamePreviewRow(source: url, name: name, status: .conflict("Another file gets this name."))
            }
            if exists(target), !sources.contains(key(target)) {
                return RenamePreviewRow(source: url, name: name, status: .conflict("A file with this name exists."))
            }
            return RenamePreviewRow(source: url, name: name, status: .ready)
        }
    }

    public static func plan(_ rows: [RenamePreviewRow]) throws -> [FileMove] {
        if let problem = rows.first(where: {
            if case .conflict = $0.status { return true }
            return false
        }), case .conflict(let reason) = problem.status {
            throw FileveroError.invalidInput("\(problem.source.lastPathComponent): \(reason)")
        }
        return rows.filter { $0.status == .ready }.map {
            FileMove(
                source: $0.source, destination: $0.source.deletingLastPathComponent().appendingPathComponent($0.name))
        }
    }

    private static func newName(
        _ url: URL, template: OutputNameTemplate, options: RenameOptions, suggestion: String?, index: Int, total: Int,
        now: Date
    ) throws -> String {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let original = url.lastPathComponent as NSString
        let ext = isDirectory ? "" : original.pathExtension
        var stem = suggestion ?? (ext.isEmpty ? url.lastPathComponent : original.deletingPathExtension)
        if !options.find.isEmpty {
            stem = stem.replacingOccurrences(of: options.find, with: options.replace, options: .caseInsensitive)
        }
        let date = options.template.contains("{date}") ? options.dateSource.date(of: url, now: now) : now
        let rendered = try template.name(
            for: ext.isEmpty ? stem : stem + "." + ext, index: index, total: total, date: date, isDirectory: isDirectory
        )
        let renderedExt = ext.isEmpty ? "" : "." + ext
        let body = String(rendered.dropLast(renderedExt.count))
        let cased: String
        switch options.letterCase {
        case .keep: cased = body
        case .lower: cased = body.lowercased()
        case .upper: cased = body.uppercased()
        case .title: cased = body.capitalized
        }
        if cased + renderedExt == url.lastPathComponent { return url.lastPathComponent }
        guard !cased.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FileveroError.invalidInput("The new name would be empty.")
        }
        guard cased.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil,
            !cased.hasPrefix(".")
        else {
            throw FileveroError.invalidInput("File names cannot contain “/”, “:” or line breaks.")
        }
        return cased + renderedExt
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

// MARK: - Compatibility Bridge
public typealias BatchRename = BatchFileNamer

