import Foundation
import Network

/// Local loopback proxy server delivering authentic appcasts and encrypted streaming releases.
public final class GitHubReleaseBridge: @unchecked Sendable {
    private let client: GitHubReleaseTransport
    private let appcast: Data
    private let nonce = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "Filevero.ReleaseBridgeQueue")
    private let syncLock = NSLock()
    private var networkListener: NWListener?
    private var loopbackFeedURL: URL?
    private var pendingContinuations: [CheckedContinuation<URL, Error>] = []
    private var isTerminated = false
    private var dynamicRoutes: [String: GitHubArchiveReference] = [:]
    private var resolvedOriginalRoutes: [URL: URL] = [:]
    private var activeConnections: [UUID: ReleaseBridgeConnection] = [:]

    public init(client: GitHubReleaseTransport, appcast: Data) {
        self.client = client
        self.appcast = appcast
    }

    deinit {
        stop()
    }

    public func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            syncLock.lock()
            if isTerminated {
                syncLock.unlock()
                continuation.resume(throwing: GitHubUpdateTransportError.bridgeUnavailable)
                return
            }
            if let existingURL = loopbackFeedURL {
                syncLock.unlock()
                continuation.resume(returning: existingURL)
                return
            }
            guard !appcast.isEmpty, appcast.count <= GitHubReleaseTransport.metadataLimit else {
                syncLock.unlock()
                continuation.resume(throwing: GitHubUpdateTransportError.tooLarge)
                return
            }
            pendingContinuations.append(continuation)
            if networkListener != nil {
                syncLock.unlock()
                return
            }

            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                params.allowLocalEndpointReuse = false
                let listener = try NWListener(using: params, on: .any)
                self.networkListener = listener

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else {
                            self.stop()
                            return
                        }
                        self.syncLock.lock()
                        guard !self.isTerminated else {
                            self.syncLock.unlock()
                            return
                        }
                        let endpointURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.nonce)/appcast.xml")!
                        self.loopbackFeedURL = endpointURL
                        let waiters = self.pendingContinuations
                        self.pendingContinuations.removeAll()
                        self.syncLock.unlock()

                        for waiter in waiters {
                            waiter.resume(returning: endpointURL)
                        }
                    case .failed, .cancelled, .waiting:
                        self.stop()
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }

                syncLock.unlock()
                listener.start(queue: queue)
            } catch {
                let waiters = self.pendingContinuations
                self.pendingContinuations.removeAll()
                isTerminated = true
                syncLock.unlock()
                for waiter in waiters {
                    waiter.resume(throwing: GitHubUpdateTransportError.bridgeUnavailable)
                }
            }
        }
    }

    public func stop() {
        syncLock.lock()
        guard !isTerminated else {
            syncLock.unlock()
            return
        }
        isTerminated = true
        let listener = self.networkListener
        self.networkListener = nil
        loopbackFeedURL = nil
        let waiters = self.pendingContinuations
        self.pendingContinuations.removeAll()
        let active = Array(activeConnections.values)
        activeConnections.removeAll()
        dynamicRoutes.removeAll()
        resolvedOriginalRoutes.removeAll()
        syncLock.unlock()

        listener?.cancel()
        for waiter in waiters {
            waiter.resume(throwing: GitHubUpdateTransportError.bridgeUnavailable)
        }
        for connection in active {
            connection.cancel()
        }
    }

    public func archiveURL(for original: URL) throws -> URL {
        let ref = try client.archiveReference(for: original)
        syncLock.lock()
        defer { syncLock.unlock() }

        guard !isTerminated, let baseFeed = loopbackFeedURL else {
            throw GitHubUpdateTransportError.bridgeUnavailable
        }
        if let existing = resolvedOriginalRoutes[original] {
            return existing
        }
        guard dynamicRoutes.count < 64 else {
            throw GitHubUpdateTransportError.tooLarge
        }

        let routePath = "/\(nonce)/archive/\(UUID().uuidString)/update.zip"
        let fullURL = URL(string: routePath, relativeTo: baseFeed)!.absoluteURL
        dynamicRoutes[routePath] = ref
        resolvedOriginalRoutes[original] = fullURL
        return fullURL
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        syncLock.lock()
        guard !isTerminated, let baseFeed = loopbackFeedURL, activeConnections.count < 16 else {
            syncLock.unlock()
            connection.cancel()
            return
        }

        let peer = ReleaseBridgeConnection(
            connection: connection,
            host: "127.0.0.1:\(baseFeed.port!)",
            client: client,
            route: { [weak self] path in
                guard let self else { return nil }
                self.syncLock.lock()
                defer { self.syncLock.unlock() }
                guard !self.isTerminated else { return nil }
                if path == "/\(self.nonce)/appcast.xml" {
                    return .feed(self.appcast)
                }
                return self.dynamicRoutes[path].map(ReleaseBridgeRoute.archive)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.syncLock.lock()
                self.activeConnections.removeValue(forKey: connectionID)
                self.syncLock.unlock()
            }
        )

        activeConnections[connectionID] = peer
        syncLock.unlock()
        peer.start(on: queue)
    }
}

public enum ReleaseBridgeRoute {
    case feed(Data)
    case archive(GitHubArchiveReference)
}

public final class ReleaseBridgeConnection: GitHubArchiveSink, @unchecked Sendable {
    private let connection: NWConnection
    private let expectedHost: String
    private let client: GitHubReleaseTransport
    private let routeLookup: (String) -> ReleaseBridgeRoute?
    private let terminationHandler: () -> Void
    private let stateLock = NSLock()
    private var isClosed = false
    private var headersEmitted = false
    private var requestBuffer = Data()
    private var streamTask: Task<Void, Never>?
    private var connectionTimeout: DispatchWorkItem?

    public init(
        connection: NWConnection,
        host: String,
        client: GitHubReleaseTransport,
        route: @escaping (String) -> ReleaseBridgeRoute?,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.expectedHost = host
        self.client = client
        self.routeLookup = route
        self.terminationHandler = onClose
    }

    public func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancel()
            default:
                break
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.cancel()
        }
        self.connectionTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)

        connection.start(queue: queue)
        readRequest()
    }

    public func cancel() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        let task = streamTask
        streamTask = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        stateLock.unlock()

        task?.cancel()
        connection.cancel()
        terminationHandler()
    }

    private func readRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, 8192 - requestBuffer.count)) {
            [weak self] chunk, _, complete, error in
            guard let self else { return }
            if let chunk { self.requestBuffer.append(chunk) }

            if let delimiter = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                self.processHeaders(Data(self.requestBuffer[..<delimiter.lowerBound]))
            } else if self.requestBuffer.count >= 8192 {
                self.sendReply(statusCode: "431 Request Header Fields Too Large", body: Data())
            } else if complete || error != nil {
                self.cancel()
            } else {
                self.readRequest()
            }
        }
    }

    private func processHeaders(_ data: Data) {
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .utf8)
        else {
            sendReply(statusCode: "400 Bad Request", body: Data())
            return
        }

        let lines = text.components(separatedBy: "\r\n")
        let requestTokens = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestTokens.count == 3, requestTokens[2] == "HTTP/1.1" || requestTokens[2] == "HTTP/1.0" else {
            sendReply(statusCode: "400 Bad Request", body: Data())
            return
        }
        guard requestTokens[0] == "GET" else {
            sendReply(statusCode: "405 Method Not Allowed", body: Data())
            return
        }

        let targetURI = String(requestTokens[1])
        guard targetURI.hasPrefix("/"), !targetURI.hasPrefix("//"), !targetURI.contains("#") else {
            sendReply(statusCode: "400 Bad Request", body: Data())
            return
        }

        var headerHosts: [String] = []
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":"), colonIndex != line.startIndex else {
                sendReply(statusCode: "400 Bad Request", body: Data())
                return
            }
            let name = line[..<colonIndex].lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if name == "host" { headerHosts.append(value) }
            if name == "transfer-encoding" || (name == "content-length" && value != "0") {
                sendReply(statusCode: "400 Bad Request", body: Data())
                return
            }
        }

        guard headerHosts == [expectedHost] else {
            sendReply(statusCode: "400 Bad Request", body: Data())
            return
        }

        let pathOnly = String(targetURI.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let route = routeLookup(pathOnly) else {
            sendReply(statusCode: "404 Not Found", body: Data())
            return
        }

        switch route {
        case .feed(let xmlBody):
            sendReply(statusCode: "200 OK", body: xmlBody, contentType: "application/rss+xml")
        case .archive(let reference):
            stateLock.lock()
            guard !isClosed else {
                stateLock.unlock()
                return
            }
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.streamArchive(reference, to: self)
                    self.finalizeResponse()
                } catch {
                    if self.hasSentHeaders() {
                        self.cancel()
                    } else {
                        self.sendReply(
                            statusCode: "502 Bad Gateway",
                            body: Data("The private update download failed. Check your update settings and retry.".utf8)
                        )
                    }
                }
            }
            stateLock.unlock()
        }
    }

    private func sendReply(statusCode: String, body: Data, contentType: String = "text/plain") {
        let headerText = "HTTP/1.1 \(statusCode)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var packet = Data(headerText.utf8)
        packet.append(body)
        transmit(packet) { [weak self] _ in
            self?.finalizeResponse()
        }
    }

    private func hasSentHeaders() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return headersEmitted
    }

    public func beginArchive(length: Int64, filename: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let sanitizedName = String(filename.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar)) {
                return Character(String(scalar))
            }
            return "_"
        })

        stateLock.lock()
        headersEmitted = true
        stateLock.unlock()

        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nContent-Disposition: attachment; filename=\"\(sanitizedName)\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        transmit(Data(header.utf8), completion: completion)
    }

    public func writeArchive(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        transmit(data, completion: completion)
    }

    private func transmit(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        stateLock.lock()
        let closed = self.isClosed
        stateLock.unlock()

        guard !closed else {
            completion(.failure(GitHubUpdateTransportError.cancelled))
            return
        }

        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil ? .success(()) : .failure(GitHubUpdateTransportError.network))
        })
    }

    private func finalizeResponse() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }
}

// Backward-compatibility aliases
public typealias GitHubUpdateBridge = GitHubReleaseBridge
public typealias GitHubBridgeRoute = ReleaseBridgeRoute
public typealias GitHubBridgeConnection = ReleaseBridgeConnection

