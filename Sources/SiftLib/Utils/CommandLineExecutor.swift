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

/// What task cancellation does to a running local subprocess.
public enum CancellationBehavior: Sendable {
    /// TERM the child, escalate to KILL after a short grace. The default: a hung
    /// local tool must never block the global watchdog.
    case terminateProcess
    /// Let the child finish despite cancellation. For post-cancellation salvage work
    /// (unzip, xcresulttool) whose results ARE the partial reports. Pair with
    /// `timeout` so even salvage cannot hang forever.
    case runToCompletion
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

    /// Idempotent TERM→grace→KILL state machine for one child process. The
    /// cancellation handler is synchronous, so it only *starts* this machine;
    /// all waiting happens on a private timer queue, never on the caller's task.
    private final class TerminationLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let process: Process
        private static let timerQueue = DispatchQueue(label: "sift.process.termination")

        init(process: Process) {
            self.process = process
        }

        /// TERM now, KILL after `grace` if still running. Safe to call multiple
        /// times and safe to call after exit (signals to an exited pid are no-ops
        /// for Process, which tracks its own state).
        func begin(grace: TimeInterval) {
            lock.lock()
            let alreadyFired = fired
            fired = true
            lock.unlock()
            guard !alreadyFired else { return }
            if process.isRunning { process.terminate() }
            Self.timerQueue.asyncAfter(deadline: .now() + grace) { [process] in
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
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

    /// Waits for `seconds` regardless of task cancellation (a cancelled `Task.sleep`
    /// returns immediately, which would collapse grace periods and salvage timeouts).
    static func uncancellableSleep(seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    @discardableResult
    static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        onCancellation: CancellationBehavior = .terminateProcess,
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
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

        // Termination is observed via a continuation resumed in terminationHandler:
        // it waits regardless of cancellation, so terminationStatus is never read
        // from a still-running process. One-shot latch: the handler can fire before
        // the wait starts.
        let terminationWaiter = TerminationWaiter()
        process.terminationHandler = { _ in terminationWaiter.finish() }

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

        // Only installed AFTER run() succeeded: entering a cancellation handler on an
        // already-cancelled task invokes it immediately, and terminate() on a
        // never-launched Process raises.
        let latch = TerminationLatch(process: process)

        // Independent watchdog. Detached: the caller's cancellation never propagates
        // into it, so a cancelled task cannot collapse the timeout. We cancel it
        // ourselves once the child exits.
        var watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                latch.begin(grace: 2)
            }
        }

        async let stdoutDone: Void = drain(stdoutPipe.fileHandleForReading, into: stdoutCollector)
        async let stderrDone: Void = drain(stderrPipe.fileHandleForReading, into: stderrCollector)

        switch onCancellation {
        case .terminateProcess:
            await withTaskCancellationHandler {
                await terminationWaiter.wait()
            } onCancel: {
                latch.begin(grace: 2)
            }
        case .runToCompletion:
            await terminationWaiter.wait()
        }
        watchdog?.cancel()

        // The child exited; EOF normally follows when the write ends close. A detached
        // grandchild could keep a pipe open — bound the wait and force-close our read
        // ends so a leaked writer can never wedge the caller (closing makes the
        // readability handler observe EOF/error and resume).
        let drainGuard = Task.detached {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        _ = await (stdoutDone, stderrDone)
        drainGuard.cancel()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutCollector.take(), encoding: .utf8) ?? "",
            stderr: String(data: stderrCollector.take(), encoding: .utf8) ?? "",
            terminationReason: process.terminationReason
        )
    }

    /// One-shot latch bridging terminationHandler to async waiters, tolerant of
    /// finish-before-wait.
    private final class TerminationWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        func finish() {
            lock.lock()
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    c.resume()
                    return
                }
                continuation = c
                lock.unlock()
            }
        }
    }
}
