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
    /// TERM the child's process group, escalate to KILL after a short grace. The
    /// default: a hung local tool must never block the global watchdog.
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

    /// Idempotent TERM→grace→KILL state machine for one child PROCESS GROUP. The
    /// child is spawned as its own group leader (pgid == pid), so signalling the
    /// group reaches every descendant — a `/bin/sh -c` wrapper can never leave its
    /// children (xcodebuild, xcrun, script subprocesses) running past cancellation.
    /// The cancellation handler is synchronous, so it only *starts* this machine;
    /// all waiting happens on a private timer queue, never on the caller's task.
    private final class TerminationLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let processGroup: pid_t
        private let waiter: TerminationWaiter
        private static let timerQueue = DispatchQueue(label: "sift.process.termination")

        init(processGroup: pid_t, waiter: TerminationWaiter) {
            self.processGroup = processGroup
            self.waiter = waiter
        }

        /// TERM the group now, KILL it after `grace` if the direct child has not
        /// exited. Safe to call multiple times; signals to a fully-reaped group are
        /// ESRCH no-ops, and pgid recycling is not a concern while our zombie child
        /// keeps the pid reserved (the reaper's waitpid runs after exit).
        func begin(grace: TimeInterval) {
            lock.lock()
            let alreadyFired = fired
            fired = true
            lock.unlock()
            guard !alreadyFired else { return }
            if !waiter.isFinished { kill(-processGroup, SIGTERM) }
            Self.timerQueue.asyncAfter(deadline: .now() + grace) { [processGroup, waiter] in
                if !waiter.isFinished {
                    kill(-processGroup, SIGKILL)
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
        let stdoutCollector = PipeCollector()
        let stderrCollector = PipeCollector()

        // posix_spawn (not Foundation.Process) so the child starts as the LEADER OF
        // ITS OWN PROCESS GROUP: termination signals the group and therefore the
        // whole tree, not just the direct child. dup2 file actions are exempt from
        // CLOEXEC_DEFAULT, so exactly stdin/stdout/stderr reach the child.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, currentDirectory)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let spawnStatus = posix_spawn(&pid, executable, &fileActions, &attributes, argv, environ)

        // Parent-side write ends must close (whatever the spawn outcome) or the
        // drains never see EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        guard spawnStatus == 0 else {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: -1,
                stderr: String(cString: strerror(spawnStatus)),
                stdout: ""
            )
        }

        // Blocking reaper: waitpid is the one exit signal that cannot miss an
        // already-exited child (kqueue NOTE_EXIT can). One short-lived GCD thread
        // per command, matching the pipe handlers' footprint.
        let exitStatus = ExitStatusBox()
        let terminationWaiter = TerminationWaiter()
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            exitStatus.record(status)
            terminationWaiter.finish()
        }

        let latch = TerminationLatch(processGroup: pid, waiter: terminationWaiter)

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

        // Decode waitpid status the way Foundation.Process reported it: exit code
        // for a normal exit, signal number + .uncaughtSignal for a signalled death.
        let raw = exitStatus.value
        let signalNumber = raw & 0x7f
        return CommandResult(
            status: signalNumber != 0 ? signalNumber : (raw >> 8) & 0xff,
            stdout: String(data: stdoutCollector.take(), encoding: .utf8) ?? "",
            stderr: String(data: stderrCollector.take(), encoding: .utf8) ?? "",
            terminationReason: signalNumber != 0 ? .uncaughtSignal : .exit
        )
    }

    private final class ExitStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32 = -1
        func record(_ newStatus: Int32) {
            lock.lock(); defer { lock.unlock() }
            status = newStatus
        }
        var value: Int32 {
            lock.lock(); defer { lock.unlock() }
            return status
        }
    }

    /// One-shot latch bridging the reaper thread to async waiters, tolerant of
    /// finish-before-wait.
    private final class TerminationWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

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
