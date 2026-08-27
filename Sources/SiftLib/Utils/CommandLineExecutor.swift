import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let terminationReason: Process.TerminationReason

    public var output: String { stdout }
}

public struct CommandError: Error, CustomStringConvertible, Sendable {
    public let command: String
    public let status: Int32
    public let stderr: String
    public let stdout: String

    public var description: String {
        var message = "Command failed (status \(status)): \(command)"
        if !stderr.isEmpty { message += "\nstderr: \(stderr)" }
        if stderr.isEmpty && !stdout.isEmpty { message += "\nstdout: \(stdout)" }
        return message
    }
}

enum CommandLineExecutor {

    /// Collects one pipe's bytes on the FileHandle's own dispatch queue.
    /// The readabilityHandler serializes invocations per handle, so ordering is preserved
    /// and no Swift-concurrency cooperative thread is ever blocked.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
        }

        func take() -> Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }

    private static func drain(_ handle: FileHandle, into collector: PipeCollector) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    continuation.resume()
                } else {
                    collector.append(data)
                }
            }
        }
    }

    @discardableResult
    static func launch(executable: String, arguments: [String], currentDirectory: String? = nil) async throws -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let stdoutCollector = PipeCollector()
        let stderrCollector = PipeCollector()

        // The termination handler must be installed before run() to avoid missing a fast exit.
        let terminated: AsyncStream<Void>
        let terminationContinuation: AsyncStream<Void>.Continuation
        (terminated, terminationContinuation) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in
            terminationContinuation.yield(())
            terminationContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: -1,
                stderr: "\(error)",
                stdout: ""
            )
        }

        async let stdoutDone: Void = drain(stdoutPipe.fileHandleForReading, into: stdoutCollector)
        async let stderrDone: Void = drain(stderrPipe.fileHandleForReading, into: stderrCollector)
        for await _ in terminated {}
        // EOF on both pipes is guaranteed after the child exits and the write ends close;
        // await the drains so the final buffered chunks are never lost.
        _ = await (stdoutDone, stderrDone)

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutCollector.take(), encoding: .utf8) ?? "",
            stderr: String(data: stderrCollector.take(), encoding: .utf8) ?? "",
            terminationReason: process.terminationReason
        )
    }
}
