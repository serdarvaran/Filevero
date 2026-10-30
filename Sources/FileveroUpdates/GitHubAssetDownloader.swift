import Foundation

/// Handles bounded HTTP data fetching and streaming updates from GitHub release assets.
final class GitHubAssetDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let allowAssetRedirects: Bool
    private let archiveSink: GitHubArchiveSink?
    private let expectedSize: Int64?
    private let targetFilename: String
    private let queue: OperationQueue

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var completionHandler: ((Result<Data, Error>) -> Void)?
    private var isFinished = false
    private var isCancelled = false
    private var collectedData = Data()
    private var bytesReceived: Int64 = 0
    private var redirectCount = 0
    private var pendingChunks: [Data] = []
    private var queuedBytesCount = 0
    private var isWritingChunk = false
    private var isSuspended = false
    private var upstreamHasCompleted = false
    private let maxBufferLimit = 8 * 1024 * 1024

    init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int,
        allowAssetRedirects: Bool,
        sink: GitHubArchiveSink?,
        expectedSize: Int64?,
        filename: String
    ) {
        self.request = request
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.allowAssetRedirects = allowAssetRedirects
        self.archiveSink = sink
        self.expectedSize = expectedSize
        self.targetFilename = filename
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        self.queue.name = "Filevero.GitHubAssetDownloader"
    }

    func start(_ completion: @escaping (Result<Data, Error>) -> Void) {
        queue.addOperation {
            self.completionHandler = completion
            guard !self.isCancelled else {
                self.finish(with: .failure(GitHubUpdateTransportError.cancelled))
                return
            }
            let activeSession = URLSession(configuration: self.configuration, delegate: self, delegateQueue: self.queue)
            self.session = activeSession
            let task = activeSession.dataTask(with: self.request)
            self.dataTask = task
            task.resume()
        }
    }

    func cancel() {
        queue.addOperation {
            self.isCancelled = true
            if self.completionHandler != nil {
                self.finish(with: .failure(GitHubUpdateTransportError.cancelled))
            }
        }
    }

    private func finish(with result: Result<Data, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let handler = completionHandler
        completionHandler = nil
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        pendingChunks.removeAll()
        queuedBytesCount = 0
        handler?(result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !isFinished, allowAssetRedirects, redirectCount < 5,
              let targetURL = request.url,
              let safeRedirect = try? GitHubUpdateClient.assetRedirectRequest(to: targetURL)
        else {
            completionHandler(nil)
            finish(with: .failure(GitHubUpdateTransportError.invalidAssetURL))
            return
        }
        redirectCount += 1
        completionHandler(safeRedirect)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isFinished, let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(GitHubUpdateTransportError.invalidResponse))
            return
        }

        let failure: GitHubUpdateTransportError?
        switch httpResponse.statusCode {
        case 200:
            failure = nil
        case 401:
            failure = .unauthorized
        case 403:
            let isRateLimit = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            failure = isRateLimit ? .rateLimited : .forbidden
        case 404:
            failure = .notFound
        case 429:
            failure = .rateLimited
        default:
            failure = .invalidResponse
        }

        if let error = failure {
            completionHandler(.cancel)
            finish(with: .failure(error))
            return
        }

        if let sink = archiveSink, let expected = expectedSize {
            sink.beginArchive(length: expected, filename: targetFilename) { result in
                self.queue.addOperation {
                    guard !self.isFinished else {
                        completionHandler(.cancel)
                        return
                    }
                    switch result {
                    case .success:
                        completionHandler(.allow)
                    case .failure:
                        completionHandler(.cancel)
                        self.finish(with: .failure(GitHubUpdateTransportError.network))
                    }
                }
            }
        } else {
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel)
                finish(with: .failure(GitHubUpdateTransportError.tooLarge))
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }

        if let expected = expectedSize {
            guard Int64(data.count) <= expected - bytesReceived else {
                finish(with: .failure(GitHubUpdateTransportError.invalidResponse))
                return
            }
            bytesReceived += Int64(data.count)
        }

        guard archiveSink != nil else {
            guard data.count <= maximumBytes - collectedData.count else {
                finish(with: .failure(GitHubUpdateTransportError.tooLarge))
                return
            }
            collectedData.append(data)
            return
        }

        guard data.count <= maxBufferLimit - queuedBytesCount else {
            finish(with: .failure(GitHubUpdateTransportError.tooLarge))
            return
        }

        pendingChunks.append(data)
        queuedBytesCount += data.count

        if !isSuspended {
            dataTask.suspend()
            isSuspended = true
        }
        flushPendingChunks()
    }

    private func flushPendingChunks() {
        guard !isFinished, !isWritingChunk else { return }

        guard !pendingChunks.isEmpty else {
            if upstreamHasCompleted {
                if expectedSize != bytesReceived {
                    finish(with: .failure(GitHubUpdateTransportError.invalidResponse))
                } else {
                    finish(with: .success(Data()))
                }
            } else if isSuspended {
                isSuspended = false
                dataTask?.resume()
            }
            return
        }

        isWritingChunk = true
        let chunk = pendingChunks.removeFirst()
        archiveSink?.writeArchive(chunk) { result in
            self.queue.addOperation {
                guard !self.isFinished else { return }
                self.queuedBytesCount -= chunk.count
                self.isWritingChunk = false
                switch result {
                case .success:
                    self.flushPendingChunks()
                case .failure:
                    self.finish(with: .failure(GitHubUpdateTransportError.network))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if error != nil {
            finish(with: .failure(isCancelled ? GitHubUpdateTransportError.cancelled : .network))
            return
        }

        if archiveSink == nil {
            finish(with: .success(collectedData))
        } else {
            upstreamHasCompleted = true
            flushPendingChunks()
        }
    }
}

// Backward-compatibility alias
typealias GitHubHTTPTransfer = GitHubAssetDownloader

