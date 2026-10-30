import Foundation
import LocalAuthentication
import Security

public enum UpdateCredentialError: LocalizedError, Equatable {
    case missing
    case locked
    case invalidToken
    case unavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing:
            return "Enter a GitHub token to connect this private repository."
        case .locked:
            return "macOS could not authorize access to the saved update token. Unlock your login Keychain or save the connection again."
        case .invalidToken:
            return "Enter a token without spaces or line breaks."
        case .unavailable:
            return "macOS could not access the saved update token. Try again after unlocking your login Keychain."
        }
    }
}

/// Abstract contract for secure token storage.
public protocol UpdateCredentialStore: Sendable {
    func token(for repository: GitHubRepository) throws -> String
    func authorizeToken(for repository: GitHubRepository) throws -> String
    func save(_ token: String, for repository: GitHubRepository) throws
    func remove(for repository: GitHubRepository) throws
}

extension UpdateCredentialStore {
    public func authorizeToken(for repository: GitHubRepository) throws -> String {
        try token(for: repository)
    }

    /// Asynchronously accesses the credential store without blocking the UI main actor.
    public func loadToken(for repository: GitHubRepository, authorizingAccess: Bool = false) async throws -> String {
        let token = try await Task.detached {
            try authorizingAccess ? self.authorizeToken(for: repository) : self.token(for: repository)
        }.value
        try Task.checkCancellation()
        return token
    }

    public func storeToken(_ token: String, for repository: GitHubRepository) async throws {
        try await Task.detached {
            try self.save(token, for: repository)
        }.value
    }

    public func removeToken(for repository: GitHubRepository) async throws {
        try await Task.detached {
            try self.remove(for: repository)
        }.value
    }
}

/// Native macOS Keychain service for persistent storage of GitHub authentication tokens.
public final class KeychainCredentialStore: UpdateCredentialStore, @unchecked Sendable {
    private static let synchronizationLock = NSLock()
    private let serviceIdentifier: String

    public init(service: String = "app.filevero.mac.github-updates") {
        self.serviceIdentifier = service
    }

    public static func validate(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 1_024,
              trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
        else {
            throw UpdateCredentialError.invalidToken
        }
        return trimmed
    }

    private func baseQuery(for repository: GitHubRepository) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: repository.slug.lowercased(),
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func token(for repository: GitHubRepository) throws -> String {
        try readCredential(for: repository, userInteractionAllowed: false)
    }

    public func authorizeToken(for repository: GitHubRepository) throws -> String {
        try readCredential(for: repository, userInteractionAllowed: true)
    }

    private func readCredential(for repository: GitHubRepository, userInteractionAllowed: Bool) throws -> String {
        Self.synchronizationLock.lock()
        defer { Self.synchronizationLock.unlock() }

        var query = baseQuery(for: repository)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var previousInteractionAllowed: DarwinBoolean = false
        try evaluateStatus(SecKeychainGetUserInteractionAllowed(&previousInteractionAllowed))
        try evaluateStatus(SecKeychainSetUserInteractionAllowed(userInteractionAllowed))
        defer { SecKeychainSetUserInteractionAllowed(previousInteractionAllowed.boolValue) }

        let laContext = LAContext()
        laContext.interactionNotAllowed = !userInteractionAllowed
        query[kSecUseAuthenticationContext as String] = laContext

        var itemRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &itemRef)
        try evaluateStatus(status)

        guard let secretData = itemRef as? Data,
              let retrievedToken = String(data: secretData, encoding: .utf8)
        else {
            throw UpdateCredentialError.missing
        }
        return try Self.validate(retrievedToken)
    }

    public func save(_ token: String, for repository: GitHubRepository) throws {
        let validatedToken = try Self.validate(token)
        Self.synchronizationLock.lock()
        defer { Self.synchronizationLock.unlock() }

        let query = baseQuery(for: repository)
        let payload: [String: Any] = [
            kSecValueData as String: Data(validatedToken.utf8),
            kSecAttrLabel as String: "Filevero updates · \(repository.slug)",
        ]

        var status = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            for (key, val) in payload {
                newItem[key] = val
            }
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        try evaluateStatus(status)
    }

    public func remove(for repository: GitHubRepository) throws {
        Self.synchronizationLock.lock()
        defer { Self.synchronizationLock.unlock() }

        let status = SecItemDelete(baseQuery(for: repository) as CFDictionary)
        if status != errSecItemNotFound {
            try evaluateStatus(status)
        }
    }

    private func evaluateStatus(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw UpdateCredentialError.missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw UpdateCredentialError.locked
        default:
            throw UpdateCredentialError.unavailable(status)
        }
    }
}

// Backward-compatibility alias
public typealias KeychainUpdateCredentialStore = KeychainCredentialStore

