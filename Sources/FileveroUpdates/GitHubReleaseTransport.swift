import Foundation

public enum GitHubUpdateTransportError: LocalizedError, Equatable {
    case invalidRepository
    case invalidToken
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case noRelease
    case missingAppcast
    case invalidAssetURL
    case invalidResponse
    case tooLarge
    case network
    case cancelled
    case bridgeUnavailable
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Enter a GitHub repository as owner/repository."
        case .invalidToken:
            return "Enter a valid GitHub access token."
        case .unauthorized:
            return "GitHub rejected the token. Replace an expired or revoked token."
        case .forbidden:
            return "GitHub denied access. Check repository permissions and organization approval."
        case .notFound:
            return "The repository or release asset is unavailable. Check its name and token access."
        case .rateLimited:
            return "GitHub’s request limit was reached. Try again later."
        case .noRelease:
            return "This repository has no published stable release yet."
        case .missingAppcast:
            return "The latest release does not contain an uploaded appcast.xml."
        case .invalidAssetURL:
            return "The update download is outside the configured GitHub repository."
        case .invalidResponse:
            return "GitHub returned an invalid update response."
        case .tooLarge:
            return "The update response exceeded the transport’s safe limits."
        case .network:
            return "The update connection failed. Check your connection and try again."
        case .cancelled:
            return "The update connection was cancelled."
        case .bridgeUnavailable:
            return "The private update connection is unavailable. Try checking again."
        case .invalidRequest:
            return "The private update request is invalid."
        }
    }
}

public struct GitHubRepository: Equatable, Codable, Sendable {
    public let slug: String
    public var websiteURL: URL { URL(string: "https://github.com/\(slug)")! }
    public var owner: String { String(slug.split(separator: "/")[0]) }
    public var name: String { String(slug.split(separator: "/")[1]) }

    public init(_ input: String) throws {
        var cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanInput.utf8.count <= 512 else {
            throw GitHubUpdateTransportError.invalidRepository
        }

        if cleanInput.contains("://") {
            guard let components = URLComponents(string: cleanInput),
                  components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "github.com",
                  components.port == nil || components.port == 443,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil
            else {
                throw GitHubUpdateTransportError.invalidRepository
            }
            cleanInput = components.percentEncodedPath
            guard cleanInput.hasPrefix("/") else {
                throw GitHubUpdateTransportError.invalidRepository
            }
            cleanInput.removeFirst()
        }

        if cleanInput.hasSuffix("/") { cleanInput.removeLast() }
        if cleanInput.hasSuffix(".git") { cleanInput.removeLast(4) }

        let segments = cleanInput.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 2,
              segments[0].range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil,
              segments[1].range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil,
              segments[1] != ".", segments[1] != ".."
        else {
            throw GitHubUpdateTransportError.invalidRepository
        }

        slug = segments.joined(separator: "/").lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case slug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .slug))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
    }
}

public enum GitHubArchiveReference: Equatable, Sendable {
    case release(tag: String, filename: String)
    case asset(Int64)
}

public protocol GitHubArchiveSink: AnyObject {
    func beginArchive(length: Int64, filename: String, completion: @escaping (Result<Void, Error>) -> Void)
    func writeArchive(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void)
}

public final class GitHubReleaseTransport: @unchecked Sendable {
    public let repository: GitHubRepository
    private let token: String?
    private let sessionConfiguration: URLSessionConfiguration
    public static let metadataLimit = 2 * 1024 * 1024

    public convenience init(repository: GitHubRepository, token: String?) {
        self.init(repository: repository, token: token, configuration: .ephemeral)
    }

    public init(repository: GitHubRepository, token: String?, configuration: URLSessionConfiguration) {
        self.repository = repository
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)

        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCredentialStorage = nil
        isolated.httpAdditionalHeaders = nil
        isolated.timeoutIntervalForRequest = 30
        isolated.timeoutIntervalForResource = 3600
        self.sessionConfiguration = isolated
    }

    public func validateAccess() async throws {
        struct RepositoryResponse: Decodable { let id: Int64 }
        let rawData = try await fetchAPIData([], acceptHeader: "application/vnd.github+json")
        guard let response = try? JSONDecoder().decode(RepositoryResponse.self, from: rawData), response.id > 0 else {
            throw GitHubUpdateTransportError.invalidResponse
        }
    }

    public func fetchLatestAppcast() async throws -> Data {
        let payload: Data
        do {
            payload = try await fetchAPIData(["releases", "latest"], acceptHeader: "application/vnd.github+json")
        } catch GitHubUpdateTransportError.notFound {
            throw GitHubUpdateTransportError.noRelease
        }

        guard let release = try? JSONDecoder().decode(ReleaseManifest.self, from: payload),
              release.draft != true, release.prerelease != true
        else {
            throw GitHubUpdateTransportError.invalidResponse
        }

        let candidates = release.assets.filter { $0.name == "appcast.xml" && $0.state == "uploaded" }
        guard candidates.count == 1 else {
            throw GitHubUpdateTransportError.missingAppcast
        }

        let asset = candidates[0]
        try asset.validate()
        guard asset.size <= Int64(Self.metadataLimit) else {
            throw GitHubUpdateTransportError.tooLarge
        }

        let result = try await execute(downloadRequest(asset.id), byteCap: Self.metadataLimit, allowRedirects: true)
        guard Int64(result.count) == asset.size else {
            throw GitHubUpdateTransportError.invalidResponse
        }
        return result
    }

    public func archiveReference(for original: URL) throws -> GitHubArchiveReference {
        guard Self.isHTTPS(original), original.query == nil, original.fragment == nil,
              let components = URLComponents(url: original, resolvingAgainstBaseURL: false)
        else {
            throw GitHubUpdateTransportError.invalidAssetURL
        }

        let rawSegments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawSegments.first == "", rawSegments.count == 7 else {
            throw GitHubUpdateTransportError.invalidAssetURL
        }

        let decodedParts = try rawSegments.dropFirst().map { part -> String in
            guard let unescaped = String(part).removingPercentEncoding,
                  !unescaped.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw GitHubUpdateTransportError.invalidAssetURL
            }
            return unescaped
        }

        switch original.host?.lowercased() {
        case "github.com":
            guard (decodedParts[0] + "/" + decodedParts[1]).lowercased() == repository.slug,
                  decodedParts[2] == "releases", decodedParts[3] == "download",
                  !decodedParts[4].isEmpty, decodedParts[4] != ".", decodedParts[4] != "..", decodedParts[4].utf8.count <= 1024,
                  AssetEntry.isValidName(decodedParts[5])
            else {
                throw GitHubUpdateTransportError.invalidAssetURL
            }
            return .release(tag: decodedParts[4], filename: decodedParts[5])

        case "api.github.com":
            guard decodedParts[0] == "repos",
                  (decodedParts[1] + "/" + decodedParts[2]).lowercased() == repository.slug,
                  decodedParts[3] == "releases", decodedParts[4] == "assets",
                  decodedParts[5].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let id = Int64(decodedParts[5]), id > 0
            else {
                throw GitHubUpdateTransportError.invalidAssetURL
            }
            return .asset(id)

        default:
            throw GitHubUpdateTransportError.invalidAssetURL
        }
    }

    private struct ReleaseManifest: Decodable {
        let draft: Bool?
        let prerelease: Bool?
        let assets: [AssetEntry]
    }

    private struct AssetEntry: Decodable {
        let id: Int64
        let name: String
        let size: Int64
        let state: String

        static func isValidName(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255 &&
                !value.contains("/") && !value.contains("\\") &&
                !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }

        func validate() throws {
            guard id > 0, size > 0, state == "uploaded", Self.isValidName(name) else {
                throw GitHubUpdateTransportError.invalidResponse
            }
        }
    }

    private func resolveAsset(_ reference: GitHubArchiveReference) async throws -> AssetEntry {
        let asset: AssetEntry
        switch reference {
        case .asset(let identifier):
            let data = try await fetchAPIData(["releases", "assets", String(identifier)], acceptHeader: "application/vnd.github+json")
            guard let decoded = try? JSONDecoder().decode(AssetEntry.self, from: data), decoded.id == identifier else {
                throw GitHubUpdateTransportError.invalidResponse
            }
            asset = decoded

        case .release(let tag, let filename):
            let data = try await fetchAPIData(["releases", "tags", tag], acceptHeader: "application/vnd.github+json")
            guard let release = try? JSONDecoder().decode(ReleaseManifest.self, from: data), release.draft != true else {
                throw GitHubUpdateTransportError.invalidResponse
            }
            let candidates = release.assets.filter { $0.name == filename && $0.state == "uploaded" }
            guard candidates.count == 1 else {
                throw GitHubUpdateTransportError.notFound
            }
            asset = candidates[0]
        }

        try asset.validate()
        return asset
    }

    public func streamArchive(_ reference: GitHubArchiveReference, to sink: GitHubArchiveSink) async throws {
        let asset = try await resolveAsset(reference)
        _ = try await execute(
            downloadRequest(asset.id),
            byteCap: 0,
            allowRedirects: true,
            sink: sink,
            expectedSize: asset.size,
            filename: asset.name
        )
    }

    private func fetchAPIData(_ suffix: [String], acceptHeader: String) async throws -> Data {
        try await execute(apiRequest(suffix, accept: acceptHeader), byteCap: Self.metadataLimit, allowRedirects: false)
    }

    public func apiRequest(_ suffix: [String], accept: String) throws -> URLRequest {
        let allowedSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let pathParts = ["repos", repository.owner, repository.name] + suffix

        let encoded = try pathParts.map { segment -> String in
            guard !segment.isEmpty, segment != ".", segment != "..",
                  let value = segment.addingPercentEncoding(withAllowedCharacters: allowedSet)
            else {
                throw GitHubUpdateTransportError.invalidAssetURL
            }
            return value
        }

        let targetURL = URL(string: "https://api.github.com/" + encoded.joined(separator: "/"))!
        var req = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Filevero-Private-Updater", forHTTPHeaderField: "User-Agent")

        if let token = self.token, !token.isEmpty {
            guard token.utf8.count <= 1024, token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
                throw GitHubUpdateTransportError.invalidToken
            }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func downloadRequest(_ identifier: Int64) throws -> URLRequest {
        try apiRequest(["releases", "assets", String(identifier)], accept: "application/octet-stream")
    }

    public static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443)
    }

    public static func assetRedirectRequest(to url: URL) throws -> URLRequest {
        let trustedHosts = [
            "release-assets.githubusercontent.com",
            "objects.githubusercontent.com",
            "github-releases.githubusercontent.com",
        ]
        guard isHTTPS(url), let host = url.host?.lowercased(), trustedHosts.contains(host), url.fragment == nil else {
            throw GitHubUpdateTransportError.invalidAssetURL
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        req.setValue("Filevero-Private-Updater", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func execute(
        _ request: URLRequest,
        byteCap: Int,
        allowRedirects: Bool,
        sink: GitHubArchiveSink? = nil,
        expectedSize: Int64? = nil,
        filename: String = ""
    ) async throws -> Data {
        let downloader = GitHubAssetDownloader(
            request: request,
            configuration: sessionConfiguration,
            maximumBytes: byteCap,
            allowAssetRedirects: allowRedirects,
            sink: sink,
            expectedSize: expectedSize,
            filename: filename
        )
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    downloader.start { continuation.resume(with: $0) }
                }
            },
            onCancel: { downloader.cancel() }
        )
    }
}

// Backward-compatibility alias
public typealias GitHubUpdateClient = GitHubReleaseTransport

