import Darwin
import Foundation

/// Safe, streaming local archive parser and generator utilizing macOS system `libarchive.2.dylib`.
/// Enforces directory containment boundaries, symlink sanitization, deferred link creation,
/// and expansion capacity limits (Zip bomb prevention).
public enum ArchiveContainerCodec {
    private static let libarchiveInterface = SystemLibarchiveInterface()
    
    private struct DeferredLink {
        let destination: URL
        let target: String
        let hard: Bool
    }

    public struct ExtractionSafetyLimits {
        public var maximumEntries = 100_000
        public var maximumBytes: Int64 = 20 * 1024 * 1024 * 1024
        
        public init(maximumEntries: Int = 100_000, maximumBytes: Int64 = 20 * 1024 * 1024 * 1024) {
            self.maximumEntries = maximumEntries
            self.maximumBytes = maximumBytes
        }
    }

    public static func extract(
        _ input: URL,
        into root: URL,
        password: String = "",
        token: CancellationToken,
        limits: ExtractionSafetyLimits = ExtractionSafetyLimits()
    ) throws {
        let api = try libarchiveInterface.resolve()
        guard let reader = api.readNew() else {
            throw FileveroError.failed("Could not initialize the archive reader.")
        }
        defer { _ = api.readFree(reader) }
        
        try api.check(api.readSupportFilters(reader), handle: reader)
        try api.check(api.readSupportFormats(reader), handle: reader)
        
        // A lone compressed file has no archive inside, so it is read as a raw stream.
        if let (name, signature) = singleStreamSignatures[input.pathExtension.lowercased()] {
            let prefix = try Data(contentsOf: input, options: .mappedIfSafe).prefix(signature.count)
            guard prefix.elementsEqual(signature) else {
                throw FileveroError.invalidInput("This file is not a \(name) stream.")
            }
            try api.check(api.readSupportRaw(reader), handle: reader)
        }
        
        if !password.isEmpty {
            try api.check(password.withCString { api.readPassphrase(reader, $0) }, handle: reader)
        }
        try api.check(input.path.withCString { api.readOpen(reader, $0, 128 * 1024) }, handle: reader)
        
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        
        var links: [DeferredLink] = []
        var totalEntries = 0
        var accumulatedBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        
        while true {
            try token.check()
            var entry: OpaquePointer?
            let status = api.readNext(reader, &entry)
            if status == 1 { break }
            try api.check(status, handle: reader)
            
            guard let entry, let rawName = api.entryPath(entry) else {
                throw FileveroError.failed("The archive contains an unnamed entry.")
            }
            
            var name = String(cString: rawName)
            if api.format(reader) == 0x90000 {
                name = input.deletingPathExtension().lastPathComponent
                if ["tgz", "gzip"].contains(input.pathExtension.lowercased()) && name.isEmpty {
                    name = "data"
                }
            }
            
            totalEntries += 1
            guard totalEntries <= limits.maximumEntries else {
                throw FileveroError.invalidInput("The archive has too many entries (100,000 limit).")
            }
            
            let destination = try safeURL(name, inside: root)
            if destination.standardizedFileURL == root.standardizedFileURL {
                _ = api.readSkip(reader)
                continue
            }
            
            try validateDestination(destination, root: root)
            
            if let hardlink = api.entryHardlink(entry) {
                _ = try safeURL(String(cString: hardlink), inside: root)
                links.append(.init(destination: destination, target: String(cString: hardlink), hard: true))
                _ = api.readSkip(reader)
                continue
            }
            
            if let symlink = api.entrySymlink(entry) {
                let target = String(cString: symlink)
                try validateSymbolicTarget(target, at: destination, root: root)
                links.append(.init(destination: destination, target: target, hard: false))
                _ = api.readSkip(reader)
                continue
            }
            
            let fileKind = api.entryFiletype(entry) & 0o170000
            if fileKind == 0o040000 {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            
            guard fileKind == 0o100000 || fileKind == 0 else {
                throw FileveroError.invalidInput("The archive contains an unsupported special file: \(name)")
            }
            
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw FileveroError.invalidInput("The archive contains duplicate file paths: \(name)")
            }
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw FileveroError.failed("Could not create \(name).")
            }
            
            let fileHandle = try FileHandle(forWritingTo: destination)
            do {
                while true {
                    try token.check()
                    let readCount = buffer.withUnsafeMutableBytes { api.readData(reader, $0.baseAddress, $0.count) }
                    if readCount == 0 { break }
                    guard readCount > 0 else { throw api.failure(reader) }
                    guard Int64(readCount) <= limits.maximumBytes - accumulatedBytes else {
                        throw FileveroError.invalidInput("The archive expands beyond the 20 GB safety limit.")
                    }
                    accumulatedBytes += Int64(readCount)
                    try fileHandle.write(contentsOf: Data(buffer[0..<readCount]))
                }
                try fileHandle.close()
            } catch {
                try? fileHandle.close()
                throw error
            }
            
            let posixMode = api.entryPerm(entry) & 0o777
            if posixMode != 0 {
                try? fileManager.setAttributes([.posixPermissions: NSNumber(value: posixMode)], ofItemAtPath: destination.path)
            }
            let modifiedTime = api.entryMtime(entry)
            if modifiedTime > 0 {
                try? fileManager.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedTime))],
                    ofItemAtPath: destination.path
                )
            }
        }
        
        guard totalEntries > 0 else {
            if api.format(reader) == 0 {
                throw FileveroError.invalidInput("This file is not a readable archive.")
            }
            return
        }
        
        for hardlink in links.filter(\.hard) {
            try token.check()
            try validateDestination(hardlink.destination, root: root)
            let targetURL = try safeURL(hardlink.target, inside: root)
            try validateDestination(targetURL, root: root)
            let attrs = try fileManager.attributesOfItem(atPath: targetURL.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw FileveroError.invalidInput("An archive hard link does not point to a regular file.")
            }
            try fileManager.createDirectory(at: hardlink.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.linkItem(at: targetURL, to: hardlink.destination)
        }
        
        for symlink in links.filter({ !$0.hard }) {
            try token.check()
            try validateDestination(symlink.destination, root: root)
            try validateSymbolicTarget(symlink.target, at: symlink.destination, root: root)
            try fileManager.createDirectory(at: symlink.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: symlink.destination.path, withDestinationPath: symlink.target)
        }
        
        for symlink in links where !symlink.hard {
            guard isPathContained(symlink.destination.resolvingSymlinksInPath(), within: root) else {
                throw FileveroError.invalidInput("An archive link points outside the extraction folder.")
            }
        }
    }

    /// Formats `create` can write, in menu order; gz, bz2 and xz are compressed TAR archives.
    public static let creatableFormats = ["zip", "7z", "tar", "gz", "bz2", "xz"]
    public static let writableFormats = Set(creatableFormats)

    private static let singleStreamSignatures: [String: (name: String, signature: [UInt8])] = [
        "gz": ("GZIP", [0x1f, 0x8b]),
        "gzip": ("GZIP", [0x1f, 0x8b]),
        "bz2": ("BZIP2", Array("BZh".utf8)),
        "xz": ("XZ", [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]),
    ]

    /// Compressed TAR archives keep both extensions, such as "Photos.tar.gz".
    public static func fileExtension(for format: String) -> String {
        ["gz", "bz2", "xz"].contains(format) ? "tar.\(format)" : format
    }

    /// The name without its archive extensions: "Photos.tar.gz" becomes "Photos".
    public static func baseName(of url: URL) -> String {
        let stem = url.deletingPathExtension()
        return stem.pathExtension.lowercased() == "tar"
            ? stem.deletingPathExtension().lastPathComponent : stem.lastPathComponent
    }

    public static func create(
        from root: URL,
        at output: URL,
        format: String,
        compressionLevel: Int = 6,
        token: CancellationToken
    ) throws {
        let api = try libarchiveInterface.resolve()
        guard let writer = api.writeNew() else {
            throw FileveroError.failed("Could not initialize the archive writer.")
        }
        defer { _ = api.writeFree(writer) }
        
        let level = max(0, min(9, compressionLevel))
        let compression: String?
        switch format {
        case "zip":
            try api.check(api.writeZIP(writer), handle: writer)
            compression = level == 0 ? "zip:compression=store" : "zip:compression-level=\(level)"
        case "7z":
            try api.check(api.writeSevenZip(writer), handle: writer)
            compression = level == 0 ? "7zip:compression=store" : "7zip:compression-level=\(level)"
        case "tar":
            try api.check(api.writeTar(writer), handle: writer)
            compression = nil
        case "gz", "gzip", "tgz":
            try api.check(api.writeTar(writer), handle: writer)
            try api.check(api.writeGzip(writer), handle: writer)
            compression = "gzip:compression-level=\(level)"
        case "bz2":
            try api.check(api.writeTar(writer), handle: writer)
            try api.check(api.writeBzip2(writer), handle: writer)
            compression = "bzip2:compression-level=\(max(1, level))"
        case "xz":
            try api.check(api.writeTar(writer), handle: writer)
            try api.check(api.writeXZ(writer), handle: writer)
            compression = "xz:compression-level=\(level)"
        default:
            throw FileveroError.unsupported("Cannot create \(format.uppercased()) archives.")
        }
        if let compression {
            try api.check(compression.withCString { api.writeOptions(writer, $0) }, handle: writer)
        }
        
        try api.check(output.path.withCString { api.writeOpen(writer, $0) }, handle: writer)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: root.path) else {
            throw FileveroError.failed("Could not read the extracted archive.")
        }
        
        let children = enumerator.compactMap { $0 as? String }.sorted()
        let bufferSize = 128 * 1024
        
        for relativeName in children {
            try token.check()
            let itemURL = root.appendingPathComponent(relativeName)
            _ = try safeURL(relativeName, inside: root)
            let attrs = try fileManager.attributesOfItem(atPath: itemURL.path)
            
            guard let entry = api.entryNew() else {
                throw FileveroError.failed("Could not create an archive entry.")
            }
            defer { api.entryFree(entry) }
            
            relativeName.withCString { api.entrySetPath(entry, $0) }
            api.entrySetPerm(entry, (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644)
            api.entrySetMtime(entry, Int64((attrs[.modificationDate] as? Date ?? Date()).timeIntervalSince1970), 0)
            
            let fileType = attrs[.type] as? FileAttributeType
            switch fileType {
            case .typeDirectory:
                api.entrySetType(entry, 0o040000)
                api.entrySetSize(entry, 0)
            case .typeSymbolicLink:
                let targetPath = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                try validateSymbolicTarget(targetPath, at: itemURL, root: root)
                api.entrySetType(entry, 0o120000)
                api.entrySetSize(entry, 0)
                targetPath.withCString { api.entrySetSymlink(entry, $0) }
            case .typeRegular:
                api.entrySetType(entry, 0o100000)
                api.entrySetSize(entry, (attrs[.size] as? NSNumber)?.int64Value ?? 0)
            default:
                throw FileveroError.invalidInput("Cannot archive the special file \(relativeName).")
            }
            
            try api.check(api.writeHeader(writer, entry), handle: writer)
            
            if fileType == .typeRegular {
                let file = try FileHandle(forReadingFrom: itemURL)
                defer { try? file.close() }
                while let data = try file.read(upToCount: bufferSize), !data.isEmpty {
                    try token.check()
                    try data.withUnsafeBytes { rawBytes in
                        var offset = 0
                        while offset < rawBytes.count {
                            let written = api.writeData(writer, rawBytes.baseAddress?.advanced(by: offset), rawBytes.count - offset)
                            guard written > 0 else { throw api.failure(writer) }
                            offset += written
                        }
                    }
                }
            }
            try api.check(api.writeFinish(writer), handle: writer)
        }
        try api.check(api.writeClose(writer), handle: writer)
    }

    public static func safeURL(_ path: String, inside root: URL) throws -> URL {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
              normalized.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
        else {
            throw FileveroError.invalidInput("The archive contains an absolute path.")
        }
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.contains("..") else {
            throw FileveroError.invalidInput("The archive contains a path outside its extraction folder.")
        }
        let relative = segments.filter { $0 != "." }.joined(separator: "/")
        let resolvedURL = root.appendingPathComponent(relative).standardizedFileURL
        guard isPathContained(resolvedURL, within: root) else {
            throw FileveroError.invalidInput("An archive path leaves its extraction folder.")
        }
        return resolvedURL
    }

    private static func isPathContained(_ url: URL, within root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func validateDestination(_ destination: URL, root: URL) throws {
        let base = root.standardizedFileURL
        let prefix = base.path + "/"
        let path = destination.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw FileveroError.invalidInput("An archive path leaves its extraction folder.")
        }
        
        var current = base
        for segment in path.dropFirst(prefix.count).split(separator: "/") {
            current.appendPathComponent(String(segment))
            var statBuffer = stat()
            if lstat(current.path, &statBuffer) != 0 {
                let code = errno
                if code == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard statBuffer.st_mode & S_IFMT != S_IFLNK else {
                throw FileveroError.invalidInput("An archive entry cannot be created through a symbolic link.")
            }
        }
    }

    private static func validateSymbolicTarget(_ target: String, at destination: URL, root: URL) throws {
        guard !target.hasPrefix("/"), !target.contains("\\"),
              target.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              isPathContained(destination.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL, within: root)
        else {
            throw FileveroError.invalidInput("An archive link points outside the extraction folder.")
        }
    }

    private final class SystemLibarchiveInterface: @unchecked Sendable {
        typealias New = @convention(c) () -> OpaquePointer?
        typealias Call = @convention(c) (OpaquePointer?) -> Int32
        typealias OpenRead = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
        typealias OpenWrite = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
        typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
        typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
        typealias Write = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int) -> Int
        typealias StringGet = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        typealias UIntGet = @convention(c) (OpaquePointer?) -> UInt32
        typealias TimeGet = @convention(c) (OpaquePointer?) -> Int64
        typealias Header = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
        typealias SetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
        typealias SetUInt = @convention(c) (OpaquePointer?, UInt32) -> Void
        typealias SetInt64 = @convention(c) (OpaquePointer?, Int64) -> Void
        typealias SetTime = @convention(c) (OpaquePointer?, Int64, Int) -> Void
        typealias FreeEntry = @convention(c) (OpaquePointer?) -> Void

        let libraryHandle: UnsafeMutableRawPointer?

        init() {
            libraryHandle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL)
        }

        func resolve() throws -> SystemLibarchiveInterface {
            guard libraryHandle != nil else {
                throw FileveroError.missingDependency("macOS libarchive")
            }
            return self
        }

        private func loadSymbol<T>(_ name: String, _ type: T.Type) -> T {
            guard let ptr = dlsym(libraryHandle, name) else {
                preconditionFailure("Missing libarchive symbol: \(name)")
            }
            return unsafeBitCast(ptr, to: type)
        }

        var readNew: New { loadSymbol("archive_read_new", New.self) }
        var readSupportFilters: Call { loadSymbol("archive_read_support_filter_all", Call.self) }
        var readSupportFormats: Call { loadSymbol("archive_read_support_format_all", Call.self) }
        var readSupportRaw: Call { loadSymbol("archive_read_support_format_raw", Call.self) }
        var readPassphrase: OpenWrite { loadSymbol("archive_read_add_passphrase", OpenWrite.self) }
        var readOpen: OpenRead { loadSymbol("archive_read_open_filename", OpenRead.self) }
        var readNext: Next { loadSymbol("archive_read_next_header", Next.self) }
        var readData: Read { loadSymbol("archive_read_data", Read.self) }
        var readSkip: Call { loadSymbol("archive_read_data_skip", Call.self) }
        var readFree: Call { loadSymbol("archive_read_free", Call.self) }
        var format: Call { loadSymbol("archive_format", Call.self) }
        var errorString: StringGet { loadSymbol("archive_error_string", StringGet.self) }
        var entryPath: StringGet { loadSymbol("archive_entry_pathname_utf8", StringGet.self) }
        var entrySymlink: StringGet { loadSymbol("archive_entry_symlink_utf8", StringGet.self) }
        var entryHardlink: StringGet { loadSymbol("archive_entry_hardlink_utf8", StringGet.self) }
        var entryFiletype: UIntGet { loadSymbol("archive_entry_filetype", UIntGet.self) }
        var entryPerm: UIntGet { loadSymbol("archive_entry_perm", UIntGet.self) }
        var entryMtime: TimeGet { loadSymbol("archive_entry_mtime", TimeGet.self) }
        var writeNew: New { loadSymbol("archive_write_new", New.self) }
        var writeZIP: Call { loadSymbol("archive_write_set_format_zip", Call.self) }
        var writeTar: Call { loadSymbol("archive_write_set_format_pax_restricted", Call.self) }
        var writeSevenZip: Call { loadSymbol("archive_write_set_format_7zip", Call.self) }
        var writeGzip: Call { loadSymbol("archive_write_add_filter_gzip", Call.self) }
        var writeBzip2: Call { loadSymbol("archive_write_add_filter_bzip2", Call.self) }
        var writeXZ: Call { loadSymbol("archive_write_add_filter_xz", Call.self) }
        var writeOptions: OpenWrite { loadSymbol("archive_write_set_options", OpenWrite.self) }
        var writeOpen: OpenWrite { loadSymbol("archive_write_open_filename", OpenWrite.self) }
        var writeHeader: Header { loadSymbol("archive_write_header", Header.self) }
        var writeData: Write { loadSymbol("archive_write_data", Write.self) }
        var writeFinish: Call { loadSymbol("archive_write_finish_entry", Call.self) }
        var writeClose: Call { loadSymbol("archive_write_close", Call.self) }
        var writeFree: Call { loadSymbol("archive_write_free", Call.self) }
        var entryNew: New { loadSymbol("archive_entry_new", New.self) }
        var entryFree: FreeEntry { loadSymbol("archive_entry_free", FreeEntry.self) }
        var entrySetPath: SetString { loadSymbol("archive_entry_set_pathname_utf8", SetString.self) }
        var entrySetSymlink: SetString { loadSymbol("archive_entry_set_symlink_utf8", SetString.self) }
        var entrySetPerm: SetUInt { loadSymbol("archive_entry_set_perm", SetUInt.self) }
        var entrySetType: SetUInt { loadSymbol("archive_entry_set_filetype", SetUInt.self) }
        var entrySetSize: SetInt64 { loadSymbol("archive_entry_set_size", SetInt64.self) }
        var entrySetMtime: SetTime { loadSymbol("archive_entry_set_mtime", SetTime.self) }

        func check(_ status: Int32, handle: OpaquePointer?) throws {
            guard status >= -20 else { throw failure(handle) }
        }

        func failure(_ handle: OpaquePointer?) -> FileveroError {
            let message = errorString(handle).map { String(cString: $0) } ?? "The archive could not be read or written."
            return .failed(message)
        }
    }
}

public typealias ArchiveCodec = ArchiveContainerCodec

