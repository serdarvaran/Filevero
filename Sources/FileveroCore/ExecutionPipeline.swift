import Foundation

/// Holds the captured standard output and error output from an executed process.
public struct ProcessExecutionResult: Sendable {
    public let output: Data
    public let errorOutput: Data
    
    public init(output: Data, errorOutput: Data) {
        self.output = output
        self.errorOutput = errorOutput
    }
    
    public var text: String {
        String(decoding: output, as: UTF8.self)
    }
    
    public var errorText: String {
        String(decoding: errorOutput, as: UTF8.self)
    }
}

public typealias ProcessResult = ProcessExecutionResult

/// Low-level subprocess orchestration pipeline with robust stream draining,
/// cooperative cancellation, and deterministic diagnostic extraction.
public enum ExecutionPipeline {
    
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        directory: URL? = nil,
        token: CancellationToken = .init(),
        environment: [String: String] = [:],
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) throws -> ProcessExecutionResult {
        try token.check()
        let launched = try launch(
            executable, arguments, directory: directory, environment: environment, onOutput: onOutput)
        let process = launched.process

        // Monitor execution with cooperative cancellation polling
        while process.isRunning {
            if token.isCancelled {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(2.0)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.03)
        }

        process.waitUntilExit()
        launched.streams.wait()
        return try result(of: launched, executable: executable, token: token)
    }

    /// Suspends instead of blocking a thread while the process runs, so callers on the cooperative
    /// pool or the main actor stay responsive. Cancelling the token or the calling task terminates it.
    @discardableResult
    public static func runAsync(
        _ executable: URL,
        _ arguments: [String],
        directory: URL? = nil,
        token: CancellationToken = .init(),
        environment: [String: String] = [:],
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessExecutionResult {
        try token.check()
        if Task.isCancelled { throw FileveroError.cancelled }
        let exit = CompletionSignal()
        let launched = try launch(
            executable, arguments, directory: directory, environment: environment, onOutput: onOutput,
            onExit: { exit.complete() })
        let process = launched.process

        while !exit.isComplete {
            if token.isCancelled || Task.isCancelled {
                process.terminate()
                if await !exit.wait(timeout: 2.0) {
                    kill(process.processIdentifier, SIGKILL)
                    _ = await exit.wait(timeout: nil)
                }
                break
            }
            _ = await exit.wait(timeout: 0.03)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            launched.streams.notify(queue: .global()) { continuation.resume() }
        }
        if Task.isCancelled { throw FileveroError.cancelled }
        return try result(of: launched, executable: executable, token: token)
    }

    /// Runs synchronous, subprocess-driven work (such as a multi-step media pipeline) on a dispatch thread.
    /// Swift's cooperative pool has one thread per core, so it must never wait on a subprocess.
    /// Cancellation is through the work's own token, as with the sync APIs it wraps.
    public static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private struct LaunchedProcess {
        let process: Process
        let streams: DispatchGroup
        let capture: StreamCapture
    }

    private static func launch(
        _ executable: URL,
        _ arguments: [String],
        directory: URL?,
        environment: [String: String],
        onOutput: (@Sendable (Data) -> Void)?,
        onExit: (@Sendable () -> Void)? = nil
    ) throws -> LaunchedProcess {
        let process = Process()
        process.executableURL = executable

        // Enforce sandboxed protocol restrictions for FFmpeg media tools.
        // Conversion inputs stay local even if a media container references an external playlist segment.
        let sanitizedArguments: [String]
        if ["ffmpeg", "ffprobe"].contains(executable.lastPathComponent) && !arguments.contains("-protocol_whitelist") {
            sanitizedArguments = ["-protocol_whitelist", "file,pipe,crypto,data"] + arguments
        } else {
            sanitizedArguments = arguments
        }
        process.arguments = sanitizedArguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        if let onExit { process.terminationHandler = { _ in onExit() } }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both standard streams concurrently to prevent pipe buffer deadlocks.
        let streamGroup = DispatchGroup()
        let captureBox = StreamCapture()

        streamGroup.enter()
        DispatchQueue.global().async {
            defer { streamGroup.leave() }
            let readHandle = outputPipe.fileHandleForReading
            while true {
                let chunk = readHandle.availableData
                guard !chunk.isEmpty else { break }
                captureBox.appendOutput(chunk)
                if onOutput != nil && captureBox.outputCount > 2_000_000 {
                    captureBox.trimOutput(to: 2_000_000)
                }
                onOutput?(chunk)
            }
        }

        streamGroup.enter()
        DispatchQueue.global().async {
            defer { streamGroup.leave() }
            captureBox.setError(errorPipe.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            streamGroup.wait()
            throw error
        }
        return LaunchedProcess(process: process, streams: streamGroup, capture: captureBox)
    }

    private static func result(
        of launched: LaunchedProcess, executable: URL, token: CancellationToken
    ) throws -> ProcessExecutionResult {
        try token.check()

        let process = launched.process
        guard process.terminationStatus == 0 else {
            let capturedErrors = launched.capture.getErrors()
            let diagnostic = String(decoding: capturedErrors.suffix(6000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let message = diagnostic.isEmpty
                ? "\(executable.lastPathComponent) exited with code \(process.terminationStatus)."
                : diagnostic
            throw FileveroError.failed(message)
        }

        return ProcessExecutionResult(
            output: launched.capture.getOutput(),
            errorOutput: launched.capture.getErrors()
        )
    }

    // Internal thread-safe container for streaming subprocess outputs
    private final class StreamCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var errors = Data()
        
        func appendOutput(_ chunk: Data) {
            lock.lock()
            output.append(chunk)
            lock.unlock()
        }
        
        var outputCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return output.count
        }
        
        func trimOutput(to maxCount: Int) {
            lock.lock()
            if output.count > maxCount {
                output.removeFirst(output.count - maxCount)
            }
            lock.unlock()
        }
        
        func setError(_ data: Data) {
            lock.lock()
            errors = data
            lock.unlock()
        }
        
        func getOutput() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return output
        }
        
        func getErrors() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }
    }
}

public typealias ProcessRunner = ExecutionPipeline

/// One-shot completion (a process exit, drained output streams) that async code can await with a
/// timeout instead of polling with `Thread.sleep`.
final class CompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func complete() {
        lock.lock()
        completed = true
        let pending = waiters.values
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(returning: true) }
    }

    /// Returns whether completion happened before the timeout; `nil` waits without a limit.
    /// Not cancellable on purpose: callers use it to await process shutdown even when cancelled.
    func wait(timeout: TimeInterval?) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters[id] = continuation
            lock.unlock()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { self.expire(id) }
            }
        }
    }

    private func expire(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(returning: false)
    }
}
