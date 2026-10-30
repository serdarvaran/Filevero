import CryptoKit
import Foundation

public enum ToolGroup: String, CaseIterable, Sendable {
    case media, office
}

/// Dynamic readiness status for auxiliary command line engines (FFmpeg, yt-dlp, Deno, LibreOffice).
public struct ToolSetupStatus: Equatable, Sendable {
    public var mediaReady: Bool
    public var officeReady: Bool

    public init(mediaReady: Bool, officeReady: Bool) {
        self.mediaReady = mediaReady
        self.officeReady = officeReady
    }

    public init(resolve: (String) -> URL?) {
        mediaReady = ["ffmpeg", "ffprobe", "yt-dlp", "deno"].allSatisfy { resolve($0) != nil }
        officeReady = resolve("soffice") != nil
    }

    public var ready: Bool { mediaReady && officeReady }
    public var missing: [ToolGroup] {
        ToolGroup.allCases.filter { $0 == .media ? !mediaReady : !officeReady }
    }
}

/// Transactional publisher replacing runtime binary folders only upon complete verification and staging.
enum ToolInstallation {
    static func publish(_ stage: URL, to target: URL, complete: (URL) -> Bool) throws {
        let fileManager = FileManager.default
        guard complete(stage) else {
            throw FileveroError.failed("The downloaded tools are incomplete. Please try setup again.")
        }
        if complete(target) { return }
        
        let backup = target.deletingLastPathComponent().appendingPathComponent(".previous-" + UUID().uuidString)
        let existing = fileManager.fileExists(atPath: target.path)
        if existing {
            try fileManager.moveItem(at: target, to: backup)
        }
        do {
            try fileManager.moveItem(at: stage, to: target)
        } catch {
            if existing {
                try fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        if existing {
            try? fileManager.removeItem(at: backup)
        }
    }
}

/// Orchestrates secure downloading, SHA-256 integrity verification, and staging of external runtime binaries
/// outside the sandboxed application bundle into the user's Application Support directory.
public enum ExternalToolInstaller {
    
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filevero/Tools", isDirectory: true)
    }

    public static func executable(_ name: String) -> URL? {
        let relativePath: String
        switch name {
        case "ffmpeg", "ffprobe", "yt-dlp", "deno":
            relativePath = "media-v1/\(name)"
        case "soffice":
            relativePath = "office-26.8.1/LibreOffice.app/Contents/MacOS/soffice"
        default:
            return nil
        }
        let url = root.appendingPathComponent(relativePath)
        return isUsableExecutable(url) ? url : nil
    }

    private static func isUsableExecutable(_ url: URL) -> Bool {
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
            && values.isRegularFile == true
            && (values.fileSize ?? 0) > 0
    }

    public static var status: ToolSetupStatus {
        ToolSetupStatus { try? ExternalToolResolver.executable($0) }
    }

    public static var mediaReady: Bool { status.mediaReady }
    public static var officeReady: Bool { status.officeReady }

    public static func installMedia(
        token: CancellationToken,
        progress: @escaping @Sendable (Double?, String) -> Void
    ) async throws {
        try token.check()
        try Task.checkCancellation()
        
        if mediaReady {
            progress(1.0, "Media tools are ready.")
            return
        }
        
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".media-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        
        let packages: [(String, String, String, String?)] = [
            (
                "ffmpeg",
                "https://www.osxexperts.net/ffmpeg9arm.zip",
                "591260c945d0eef150e3bf82b0ef988bd36a9cecc18ff05d6679617159f0a95e",
                "binary"
            ),
            (
                "ffprobe",
                "https://www.osxexperts.net/ffprobe9arm.zip",
                "e11c17e8200b3ee4c4c186d245e2b4053f01d56957336c1817fca0b997469106",
                "binary"
            ),
            (
                "yt-dlp",
                "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos",
                "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202",
                nil
            ),
            (
                "deno",
                "https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip",
                "5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c",
                "archive"
            ),
        ]
        
        for (index, package) in packages.enumerated() {
            try token.check()
            try Task.checkCancellation()
            
            let downloadFile = stage.appendingPathComponent("download-\(index)")
            try await CheckedToolDownload.fetch(URL(string: package.1)!, to: downloadFile, maximum: 400 * 1024 * 1024) { fraction in
                progress(fraction.map { (Double(index) + $0) / Double(packages.count) }, "Downloading \(package.0)…")
            }
            
            if package.3 != "binary" {
                try verifyDigest(downloadFile, expectedHex: package.2)
            }
            
            let finalOutput = stage.appendingPathComponent(package.0)
            if package.3 != nil {
                let unpackDir = stage.appendingPathComponent("unpack-\(index)", isDirectory: true)
                try ArchiveCodec.extract(downloadFile, into: unpackDir, token: token)
                let candidate = unpackDir.appendingPathComponent(package.0)
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw FileveroError.failed("Upstream package has no regular \(package.0) executable.")
                }
                if package.3 == "binary" {
                    try verifyDigest(candidate, expectedHex: package.2)
                }
                try fileManager.moveItem(at: candidate, to: finalOutput)
                try fileManager.removeItem(at: unpackDir)
            } else {
                try fileManager.moveItem(at: downloadFile, to: finalOutput)
            }
            
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalOutput.path)
            if fileManager.fileExists(atPath: downloadFile.path) {
                try fileManager.removeItem(at: downloadFile)
            }
        }
        
        try token.check()
        try Task.checkCancellation()
        
        let targetDir = root.appendingPathComponent("media-v1", isDirectory: true)
        try ToolInstallation.publish(stage, to: targetDir) { directory in
            ["ffmpeg", "ffprobe", "yt-dlp", "deno"].allSatisfy { isUsableExecutable(directory.appendingPathComponent($0)) }
        }
        progress(1.0, "Media tools are ready.")
    }

    public static func installOffice(
        token: CancellationToken,
        progress: @escaping @Sendable (Double?, String) -> Void
    ) async throws {
        try token.check()
        try Task.checkCancellation()
        
        if officeReady {
            progress(1.0, "Office tools are ready.")
            return
        }
        
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".office-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        
        let dmgImage = stage.appendingPathComponent("LibreOffice.dmg")
        try await CheckedToolDownload.fetch(
            URL(string: "https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/aarch64/LibreOffice_26.8.1_MacOS_aarch64.dmg")!,
            to: dmgImage,
            maximum: 400 * 1024 * 1024
        ) { progress($0.map { $0 * 0.8 }, "Downloading LibreOffice 26.8.1…") }
        
        try verifyDigest(dmgImage, expectedHex: "ca074e0b13571efb30a31fc531c5f95e997030637325e5d5de92d67aefdf0dfc")
        try token.check()
        try Task.checkCancellation()
        
        progress(nil, "Verifying and preparing office tools…")
        let mountDir = stage.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountDir, withIntermediateDirectories: false)
        
        try ExecutionPipeline.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["attach", "-nobrowse", "-readonly", "-mountpoint", mountDir.path, dmgImage.path],
            token: token
        )
        defer {
            _ = try? ExecutionPipeline.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mountDir.path])
        }
        
        let contentDir = stage.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: false)
        
        try ExecutionPipeline.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            [
                mountDir.appendingPathComponent("LibreOffice.app").path,
                contentDir.appendingPathComponent("LibreOffice.app").path,
            ],
            token: token
        )
        
        try token.check()
        try Task.checkCancellation()
        
        let targetDir = root.appendingPathComponent("office-26.8.1", isDirectory: true)
        try ToolInstallation.publish(contentDir, to: targetDir) {
            isUsableExecutable($0.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice"))
        }
        progress(1.0, "Office tools are ready.")
    }

    private static func verifyDigest(_ file: URL, expectedHex: String) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hasher = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hasher.update(data: bytes)
        }
        let actualHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHex == expectedHex else {
            throw FileveroError.failed("The upstream download checksum did not match. Nothing was installed.")
        }
    }
}

public typealias ExternalToolSetup = ExternalToolInstaller

private final class CheckedToolDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let target: URL
    private let maximumBytes: Int64
    private let progressHandler: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var capturedFailure: Error?

    private init(target: URL, maximum: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.target = target
        self.maximumBytes = maximum
        self.progressHandler = progress
    }

    static func fetch(
        _ url: URL,
        to target: URL,
        maximum: Int64,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let delegate = CheckedToolDownload(target: target, maximum: maximum, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let downloadTask = session.downloadTask(with: url)
        defer { session.finishTasksAndInvalidate() }
        
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.continuation = continuation
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        delegate.continuation = nil
                        return
                    }
                    downloadTask.resume()
                }
            },
            onCancel: { downloadTask.cancel() }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            capturedFailure = FileveroError.failed("The upstream download exceeds its size limit.")
            downloadTask.cancel()
            return
        }
        progressHandler(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  response.url?.scheme == "https"
            else {
                throw FileveroError.failed("The upstream server did not return a successful HTTPS download.")
            }
            let fileSize = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize > 0, fileSize <= maximumBytes else {
                throw FileveroError.failed("The upstream download has an invalid size.")
            }
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            capturedFailure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let cont = continuation else { return }
        self.continuation = nil
        if let failure = capturedFailure ?? error {
            cont.resume(throwing: failure)
        } else {
            cont.resume()
        }
    }
}

