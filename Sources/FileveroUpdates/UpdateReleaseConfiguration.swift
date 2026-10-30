import Foundation

/// Update verification configuration pinned in the signed application bundle.
/// Guarantees feeds and update artifacts satisfy cryptographic signature requirements.
public struct UpdateReleaseConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    public enum ConfigurationError: LocalizedError, Equatable {
        case notConfigured
        case missingFeed
        case insecureFeed
        case invalidPublicKey
        case missingVerification

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Updates aren’t connected yet. This build needs a release feed and an update signing key."
            case .missingFeed:
                return "The update signing key is ready. Connect a GitHub repository to enable updates."
            case .insecureFeed:
                return "The update feed must use HTTPS. Local development feeds must use a loopback address."
            case .invalidPublicKey:
                return "This build has an invalid update signing key."
            case .missingVerification:
                return "This build must verify signed update feeds and downloads."
            }
        }
    }

    public init(info: [String: Any], repository: GitHubRepository? = nil) throws {
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty else {
            throw ConfigurationError.notConfigured
        }

        let feed = (info["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? repository.map {
                $0.websiteURL.appendingPathComponent("releases/latest/download/appcast.xml").absoluteString
            }

        guard let feedString = feed else {
            throw ConfigurationError.missingFeed
        }

        guard let parsedURL = URL(string: feedString),
              let host = parsedURL.host, !host.isEmpty,
              parsedURL.user == nil, parsedURL.password == nil, parsedURL.fragment == nil
        else {
            throw ConfigurationError.insecureFeed
        }

        let isLocalDev = info["FileveroLocalUpdateFeed"] as? Bool == true
        let isLoopback = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host.lowercased())

        guard !isLocalDev || isLoopback,
              parsedURL.scheme?.lowercased() == "https" || (isLocalDev && isLoopback && parsedURL.scheme?.lowercased() == "http")
        else {
            throw ConfigurationError.insecureFeed
        }

        guard let keyBytes = Data(base64Encoded: key), keyBytes.count == 32 else {
            throw ConfigurationError.invalidPublicKey
        }

        guard info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true
        else {
            throw ConfigurationError.missingVerification
        }

        self.feedURL = parsedURL
        self.publicKey = key
    }
}

// Backward-compatibility alias
public typealias UpdateConfiguration = UpdateReleaseConfiguration

