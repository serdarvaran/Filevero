import CryptoKit
import Foundation
import Security

public enum UpdateCredentialBrokerError: Error, LocalizedError, Equatable {
    case unavailable
    case identity
    case connection
    case denied
    case timeout

    public var errorDescription: String? {
        switch self {
        case .identity:
            return "The update connection could not be verified. Reinstall a verified Filevero build to repair it."
        case .denied:
            return "The saved update token is unavailable. Open Update Connection to authorize access."
        case .connection, .timeout, .unavailable:
            return "The saved update connection did not respond. Try again."
        }
    }
}

public struct UpdateCredentialBrokerConfiguration: Equatable, Sendable {
    public static let service = "app.filevero.mac.credentials.v1"
    public let appURL: URL
    public let certificateSHA1: String
    public let binarySHA256: String
    public let bundleSHA256: String

    public var requirement: String {
        "identifier \"\(Self.service)\" and certificate leaf = H\"\(certificateSHA1)\""
    }

    public var bundleURL: URL {
        appURL.appendingPathComponent("Contents/XPCServices/\(Self.service).xpc", isDirectory: true)
    }

    public init(appURL: URL, info: [String: Any]) throws {
        func parseHexHash(_ key: String, expectedLength: Int) throws -> String {
            guard let val = info[key] as? String,
                  val.count == expectedLength,
                  val.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else {
                throw UpdateCredentialBrokerError.identity
            }
            return val.lowercased()
        }

        guard info["FileveroCredentialBrokerService"] as? String == Self.service else {
            throw UpdateCredentialBrokerError.identity
        }

        self.appURL = appURL.standardizedFileURL
        self.certificateSHA1 = try parseHexHash("FileveroCredentialBrokerCertificateSHA1", expectedLength: 40)
        self.binarySHA256 = try parseHexHash("FileveroCredentialBrokerBinarySHA256", expectedLength: 64)
        self.bundleSHA256 = try parseHexHash("FileveroCredentialBrokerBundleSHA256", expectedLength: 64)
    }
}

public protocol UpdateCredentialBrokerTransport: AnyObject, Sendable {
    var onFailure: (@Sendable () -> Void)? { get set }
    func setRequirement(_ requirement: String)
    func resume()
    func handshake(_ reply: @escaping @Sendable (Bool) -> Void)
    func read(repository: String, allowInteraction: Bool, reply: @escaping @Sendable (String?, Bool) -> Void)
    func write(_ token: String, repository: String, reply: @escaping @Sendable (Bool) -> Void)
    func remove(repository: String, _ reply: @escaping @Sendable (Bool) -> Void)
    func invalidate()
}

public final class NativeCredentialBrokerTransport: UpdateCredentialBrokerTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let stateLock = NSLock()
    private var failureCallback: (@Sendable () -> Void)?

    public var onFailure: (@Sendable () -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return failureCallback
        }
        set {
            stateLock.lock()
            failureCallback = newValue
            stateLock.unlock()
        }
    }

    public init(service: String) {
        connection = NSXPCConnection(serviceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateCredentialBrokerProtocol.self)
        connection.interruptionHandler = { [weak self] in self?.onFailure?() }
        connection.invalidationHandler = { [weak self] in self?.onFailure?() }
    }

    private var proxyObject: UpdateCredentialBrokerProtocol? {
        connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.onFailure?()
        } as? UpdateCredentialBrokerProtocol
    }

    public func setRequirement(_ requirement: String) {
        connection.setCodeSigningRequirement(requirement)
    }

    public func resume() {
        connection.resume()
    }

    public func handshake(_ reply: @escaping @Sendable (Bool) -> Void) {
        guard let proxy = proxyObject else {
            onFailure?()
            return
        }
        proxy.handshake { reply($0 == nil) }
    }

    public func read(repository: String, allowInteraction: Bool, reply: @escaping @Sendable (String?, Bool) -> Void) {
        guard let proxy = proxyObject else {
            onFailure?()
            return
        }
        proxy.readToken(repository: repository, allowInteraction: allowInteraction) { reply($0, $1 == nil) }
    }

    public func write(_ token: String, repository: String, reply: @escaping @Sendable (Bool) -> Void) {
        guard let proxy = proxyObject else {
            onFailure?()
            return
        }
        proxy.writeToken(token, repository: repository) { reply($0 == nil) }
    }

    public func remove(repository: String, _ reply: @escaping @Sendable (Bool) -> Void) {
        guard let proxy = proxyObject else {
            onFailure?()
            return
        }
        proxy.deleteToken(repository: repository) { reply($0 == nil) }
    }

    public func invalidate() {
        onFailure = nil
        connection.invalidate()
    }
}

public final class CredentialBrokerReplyBox<Value: Sendable>: @unchecked Sendable {
    private let gateLock = NSLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var storedResult: Result<Value, Error>?
    private var isTerminated = false

    public init() {}

    public func finish(_ result: Result<Value, Error>) {
        gateLock.lock()
        guard !isTerminated, storedResult == nil else {
            gateLock.unlock()
            return
        }
        storedResult = result
        gateLock.unlock()
        completionSignal.signal()
    }

    public func wait(until deadline: DispatchTime) throws -> Value {
        let success = completionSignal.wait(timeout: deadline) == .success
        gateLock.lock()
        isTerminated = true
        let response = storedResult
        storedResult = nil
        gateLock.unlock()

        guard success, let response else {
            throw UpdateCredentialBrokerError.timeout
        }
        return try response.get()
    }
}

public final class CredentialBrokerClient: @unchecked Sendable {
    public static let live = CredentialBrokerClient()

    private let configSupplier: @Sendable () throws -> UpdateCredentialBrokerConfiguration
    private let bundleValidator: @Sendable (UpdateCredentialBrokerConfiguration) throws -> Void
    private let transportFactory: @Sendable (String) -> UpdateCredentialBrokerTransport
    private let standardTimeout: TimeInterval
    private let interactiveTimeout: TimeInterval

    public init(
        timeout: TimeInterval = 12,
        authorizationTimeout: TimeInterval = 120,
        configuration: @escaping @Sendable () throws -> UpdateCredentialBrokerConfiguration = {
            try UpdateCredentialBrokerConfiguration(appURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])
        },
        validate: @escaping @Sendable (UpdateCredentialBrokerConfiguration) throws -> Void = {
            try CredentialBrokerClient.validateBundle($0)
        },
        connect: @escaping @Sendable (String) -> UpdateCredentialBrokerTransport = {
            NativeCredentialBrokerTransport(service: $0)
        }
    ) {
        self.standardTimeout = timeout.isFinite ? max(0.01, min(30, timeout)) : 12
        self.interactiveTimeout = authorizationTimeout.isFinite ? max(0.01, min(180, authorizationTimeout)) : 120
        self.configSupplier = configuration
        self.bundleValidator = validate
        self.transportFactory = connect
    }

    public func readToken(repository: GitHubRepository, allowInteraction: Bool = false) throws -> String? {
        try execute(timeout: allowInteraction ? interactiveTimeout : standardTimeout) { transport, reply in
            transport.read(repository: repository.slug, allowInteraction: allowInteraction) { token, success in
                let valid = token.map { (try? KeychainCredentialStore.validate($0)) == $0 } ?? true
                reply.finish(success && valid ? .success(token) : .failure(UpdateCredentialBrokerError.denied))
            }
        }
    }

    public func writeToken(_ token: String, repository: GitHubRepository) throws {
        try execute(timeout: standardTimeout) { transport, reply in
            transport.write(token, repository: repository.slug) { success in
                reply.finish(success ? .success(()) : .failure(UpdateCredentialBrokerError.denied))
            }
        }
    }

    public func deleteToken(repository: GitHubRepository) throws {
        try execute(timeout: standardTimeout) { transport, reply in
            transport.remove(repository: repository.slug) { success in
                reply.finish(success ? .success(()) : .failure(UpdateCredentialBrokerError.denied))
            }
        }
    }

    private func execute<Value: Sendable>(
        timeout: TimeInterval,
        sendAction: @escaping (UpdateCredentialBrokerTransport, CredentialBrokerReplyBox<Value>) -> Void
    ) throws -> Value {
        guard !Thread.isMainThread else {
            throw UpdateCredentialBrokerError.unavailable
        }

        let config = try configSupplier()
        try bundleValidator(config)

        let transport = transportFactory(UpdateCredentialBrokerConfiguration.service)
        defer { transport.invalidate() }

        let deadline = DispatchTime.now() + timeout
        let handshakeBox = CredentialBrokerReplyBox<Void>()
        let resultBox = CredentialBrokerReplyBox<Value>()

        transport.onFailure = {
            handshakeBox.finish(.failure(UpdateCredentialBrokerError.connection))
            resultBox.finish(.failure(UpdateCredentialBrokerError.connection))
        }

        transport.setRequirement(config.requirement)
        transport.resume()
        transport.handshake { success in
            handshakeBox.finish(success ? .success(()) : .failure(UpdateCredentialBrokerError.identity))
        }

        try handshakeBox.wait(until: deadline)
        sendAction(transport, resultBox)
        return try resultBox.wait(until: deadline)
    }

    public static func validateBundle(_ config: UpdateCredentialBrokerConfiguration) throws {
        let bundle = config.bundleURL
        guard bundle.resolvingSymlinksInPath().path == bundle.path,
              let metadata = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              metadata["CFBundleIdentifier"] as? String == UpdateCredentialBrokerConfiguration.service,
              let executable = metadata["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable == URL(fileURLWithPath: executable).lastPathComponent
        else {
            throw UpdateCredentialBrokerError.identity
        }

        let binaryURL = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
        guard try computeFileHash(binaryURL) == config.binarySHA256,
              try computeBundleHash(bundle) == config.bundleSHA256
        else {
            throw UpdateCredentialBrokerError.identity
        }

        var staticCode: SecStaticCode?
        var codeRequirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecRequirementCreateWithString(config.requirement as CFString, SecCSFlags(), &codeRequirement) == errSecSuccess,
              let codeRequirement,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                codeRequirement
              ) == errSecSuccess
        else {
            throw UpdateCredentialBrokerError.identity
        }
    }

    private static func computeFileHash(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              (0...67_108_864).contains(size)
        else {
            throw UpdateCredentialBrokerError.identity
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func bundleHash(_ bundle: URL) throws -> String {
        try computeBundleHash(bundle)
    }

    public static func computeBundleHash(_ bundle: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            throw UpdateCredentialBrokerError.identity
        }

        var catalog: [(String, URL)] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw UpdateCredentialBrokerError.identity }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, catalog.count < 256 else { throw UpdateCredentialBrokerError.identity }
            catalog.append((String(item.path.dropFirst(bundle.path.count + 1)), item))
        }

        guard !catalog.isEmpty else { throw UpdateCredentialBrokerError.identity }
        var digestData = Data()
        for (relPath, fileURL) in catalog.sorted(by: { $0.0 < $1.0 }) {
            guard !relPath.contains("\0"), !relPath.contains("\n"), !relPath.contains("\\") else {
                throw UpdateCredentialBrokerError.identity
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let posixMode = attrs[.posixPermissions] as? NSNumber else {
                throw UpdateCredentialBrokerError.identity
            }
            let row = "\(relPath)\0\(String(format: "%04o", posixMode.intValue & 0o7777))\0\(try computeFileHash(fileURL))\n"
            digestData.append(Data(row.utf8))
        }

        return SHA256.hash(data: digestData).map { String(format: "%02x", $0) }.joined()
    }
}

/// Secure broker wrapper fulfilling the UpdateCredentialStore interface.
public final class BrokerCredentialStore: UpdateCredentialStore, @unchecked Sendable {
    private let client: CredentialBrokerClient

    public init() {
        self.client = .live
    }

    public init(client: CredentialBrokerClient) {
        self.client = client
    }

    public func token(for repository: GitHubRepository) throws -> String {
        try fetchToken(for: repository, userInteractionAllowed: false)
    }

    public func authorizeToken(for repository: GitHubRepository) throws -> String {
        try fetchToken(for: repository, userInteractionAllowed: true)
    }

    private func fetchToken(for repository: GitHubRepository, userInteractionAllowed: Bool) throws -> String {
        do {
            guard let token = try client.readToken(repository: repository, allowInteraction: userInteractionAllowed) else {
                throw UpdateCredentialError.missing
            }
            return try KeychainCredentialStore.validate(token)
        } catch UpdateCredentialBrokerError.denied {
            throw UpdateCredentialError.locked
        }
    }

    public func save(_ token: String, for repository: GitHubRepository) throws {
        do {
            let validated = try KeychainCredentialStore.validate(token)
            try client.writeToken(validated, repository: repository)
        } catch UpdateCredentialBrokerError.denied {
            throw UpdateCredentialError.locked
        }
    }

    public func remove(for repository: GitHubRepository) throws {
        do {
            try client.deleteToken(repository: repository)
        } catch UpdateCredentialBrokerError.denied {
            throw UpdateCredentialError.locked
        }
    }
}

// Backward-compatibility aliases
public typealias UpdateCredentialBrokerClient = CredentialBrokerClient
public typealias BrokerUpdateCredentialStore = BrokerCredentialStore

