import Foundation

/// Official anonymous release channel fixed within the signed application bundle.
/// Verifies whether the update feed corresponds to the authentic official distribution channel.
public struct UpdateChannelDescriptor: Equatable, Sendable {
    public let repository: GitHubRepository

    public init?(info: [String: Any]) {
        guard let slug = info["FileveroPublicUpdateRepository"] as? String,
              let repo = try? GitHubRepository(slug),
              info["SUFeedURL"] as? String == repo.websiteURL.appendingPathComponent("releases/latest/download/appcast.xml").absoluteString
        else {
            return nil
        }
        self.repository = repo
    }

    /// Migrates custom repository configuration matching the official release back to the anonymous channel.
    public func migrate(_ defaults: UserDefaults) {
        let repoKey = "FileveroUpdateGitHubRepository"
        guard let saved = defaults.string(forKey: repoKey),
              saved.lowercased() == repository.slug
        else {
            return
        }

        for key in [repoKey, "FileveroUpdateGitHubRequiresToken", "FileveroUpdateGitHubSavedToken"] {
            defaults.removeObject(forKey: key)
        }

        if let autoCheck = defaults.object(forKey: "FileveroUpdateGitHubAutomaticChecks") as? Bool {
            defaults.set(autoCheck, forKey: "SUEnableAutomaticChecks")
        }
        defaults.set(repository.slug, forKey: "FileveroPublicChannelMigration")
    }
}

// Backward-compatibility alias
public typealias PublicUpdateChannel = UpdateChannelDescriptor

