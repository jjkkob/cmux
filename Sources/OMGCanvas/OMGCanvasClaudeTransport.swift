import Darwin
import Foundation

/// Owns the CLI and drains both output pipes without blocking the UI actor.
actor OMGCanvasClaudeTransport {
    enum Event: Sendable {
        case line(Data)
        case diagnostic(Data)
        case exited(Int32)
        case oversizedLine
    }

    private var process: Process?
    private var input: FileHandle?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var killDeadline: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: Task<Void, Never>?

    func start(executableURL: URL, arguments: [String], environment: [String: String], cwd: String, supervisorURL: URL? = nil) throws -> AsyncStream<Event> {
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = supervisorURL ?? executableURL
        child.arguments = supervisorURL == nil ? arguments : ["__owned-process-supervisor", executableURL.path] + arguments
        child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let (events, sink) = AsyncStream<Event>.makeStream()
        let (exitEvents, exitSink) = AsyncStream<Int32>.makeStream()
        child.terminationHandler = { child in
            exitSink.yield(child.terminationStatus)
            exitSink.finish()
        }
        try child.run()
        process = child
        inputPipe = stdin
        input = stdin.fileHandleForWriting
        outputPipe = stdout
        errorPipe = stderr
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        // Only raw descriptors cross into detached readers; the actor retains their handles until EOF.
        let outputDescriptor = stdout.fileHandleForReading.fileDescriptor
        let errorDescriptor = stderr.fileHandleForReading.fileDescriptor
        let outputReader = Task.detached { Self.drain(outputDescriptor, diagnostic: false, sink: sink) }
        let errorReader = Task.detached { Self.drain(errorDescriptor, diagnostic: true, sink: sink) }
        completion = Task {
            var status: Int32 = -1
            for await value in exitEvents { status = value }
            await outputReader.value
            await errorReader.value
            self.finished()
            sink.yield(.exited(status))
            sink.finish()
        }
        return events
    }

    func write(_ data: Data) throws {
        guard let input, process?.isRunning == true else { throw CocoaError(.fileWriteUnknown) }
        try input.write(contentsOf: data)
    }

    /// Shutdown is distinct from the protocol-level conversational interrupt.
    func shutdown() async {
        guard let process else { return }
        try? input?.close()
        input = nil
        if process.isRunning { process.terminate() }
        if killDeadline == nil {
            // A genuine shutdown deadline, cancelled as soon as the owned child exits.
            killDeadline = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self.forceStop()
            }
        }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    private func forceStop() {
        guard let process, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func finished() {
        killDeadline?.cancel()
        killDeadline = nil
        try? input?.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        input = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private nonisolated static func drain(_ descriptor: Int32, diagnostic: Bool, sink: AsyncStream<Event>.Continuation) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            if diagnostic {
                sink.yield(.diagnostic(Data(chunk.prefix(count))))
                continue
            }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0a) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= 16 * 1_024 * 1_024 else { sink.yield(.oversizedLine); return }
                sink.yield(.line(Data(buffer[..<newline])))
                buffer.removeSubrange(...newline)
            }
            guard buffer.count <= 16 * 1_024 * 1_024 else {
                sink.yield(.oversizedLine)
                return
            }
        }
        if !diagnostic && !buffer.isEmpty { sink.yield(.line(buffer)) }
    }
}
