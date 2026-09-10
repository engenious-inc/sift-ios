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

    /// Collects one pipe's bytes. With `tailLimit` set only the LAST `tailLimit`
    /// bytes are retained (amortized trim at 2×), so a runaway child — a setup
    /// script in a logging loop — cannot balloon the controller's memory; the
    /// stream is always drained fully either way.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let tailLimit: Int?

        init(tailLimit: Int? = nil) {
            self.tailLimit = tailLimit
        }

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            if let tailLimit, buffer.count > tailLimit * 2 {
                buffer.removeFirst(buffer.count - tailLimit)
            }
        }

        func take() -> Data {
            lock.lock(); defer { lock.unlock() }
            if let tailLimit, buffer.count > tailLimit {
                buffer.removeFirst(buffer.count - tailLimit)
            }
            return buffer
        }
    }

    /// Drains one pipe read end into a collector through a dispatch read source,
    /// and can be ENDED early by `end()`.
    ///
    /// Not `FileHandle.readabilityHandler`: on Darwin, closing a handle while its
    /// handler is installed cancels the underlying read source WITHOUT a final
    /// handler call, so "close the read end to force EOF" leaves the waiter
    /// suspended forever (a leaked continuation). A read source's cancel handler
    /// runs after any in-flight event handler, on the same queue — closing the
    /// descriptor and resuming the waiter there is the one race-free ordering.
    private final class PipeDrain: @unchecked Sendable {
        private static let queue = DispatchQueue(label: "sift.process.drain", attributes: .concurrent)
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        private let source: DispatchSourceRead

        init(handle: FileHandle, collector: PipeCollector) {
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: Self.queue)
            self.source = source
            source.setEventHandler { [collector] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        collector.append(Data(buffer[0..<count]))
                        continue
                    }
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 && errno == EAGAIN { return }   // drained for now; wait for the next event
                    source.cancel()                                // EOF (0) or a hard read error
                    return
                }
            }
            source.setCancelHandler { [weak self] in
                try? handle.close()
                self?.finish()
            }
            source.resume()
        }

        private func finish() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            finished = true
            lock.unlock()
            continuation?.resume()
        }

        /// Resumes on EOF, on a read error, or once `end()` has run.
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        /// Ends the drain now (idempotent): the descriptor closes and `wait()`
        /// returns even if a leaked writer still holds the pipe open.
        func end() {
            source.cancel()
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
        private static let timerQueue = DispatchQueue(label: "sift.process.termination")

        init(processGroup: pid_t) {
            self.processGroup = processGroup
        }

        /// TERM the group now, KILL it after `grace` if the GROUP still has live
        /// members. Liveness is the group's (`kill(-pgid, 0)`), never the direct
        /// child's: a leader that exits on TERM must not shield a TERM-ignoring
        /// descendant from the KILL. Safe to call multiple times; a pgid is not
        /// recycled while any member (zombies included) remains, and signalling a
        /// dissolved group is an ESRCH no-op.
        func begin(grace: TimeInterval) {
            lock.lock()
            let alreadyFired = fired
            fired = true
            lock.unlock()
            guard !alreadyFired else { return }
            if kill(-processGroup, 0) == 0 { kill(-processGroup, SIGTERM) }
            Self.timerQueue.asyncAfter(deadline: .now() + grace) { [processGroup] in
                if kill(-processGroup, 0) == 0 {
                    kill(-processGroup, SIGKILL)
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

    /// `outputTailLimit`: retain only the last N bytes of each stream (nil = all).
    /// Callers that parse the output (xcresulttool JSON, nm) leave it nil; the
    /// local transport caps user scripts exactly like the SSH transport does.
    @discardableResult
    static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        onCancellation: CancellationBehavior = .terminateProcess,
        timeout: TimeInterval? = nil,
        outputTailLimit: Int? = nil
    ) async throws -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCollector = PipeCollector(tailLimit: outputTailLimit)
        let stderrCollector = PipeCollector(tailLimit: outputTailLimit)

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
        // The CLI ignores SIGINT/SIGTERM (dispatch signal sources) and SIGPIPE, and
        // ignored dispositions SURVIVE exec: without SETSIGDEF every local child —
        // zip, xcresulttool, the /bin/sh wrappers, user scripts, xcodebuild — would
        // start with TERM ignored, turning the TERM→KILL grace into KILL-only and
        // making a non-interactive sh unable to trap TERM at all. Restore the
        // defaults and an empty mask in the child.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        ))
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
        let waitResult = WaitResultBox()
        let terminationWaiter = TerminationWaiter()
        DispatchQueue.global().async { [pid] in
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            // A non-EINTR failure (e.g. ECHILD when a supervisor left SIGCHLD
            // ignored and the kernel auto-reaped) means the exit status is
            // unknowable — recording `status` here would fabricate exit 0.
            waitResult.record(reaped == pid ? .exited(status) : .waitFailed(errno))
            terminationWaiter.finish()
        }

        let latch = TerminationLatch(processGroup: pid)

        // Independent watchdog. Detached: the caller's cancellation never propagates
        // into it, so a cancelled task cannot collapse the timeout. We cancel it
        // ourselves once the child exits.
        var watchdog: Task<Void, Never>?
        if let timeout {
            // Public API: a negative, NaN, or absurd interval must not trap in the
            // UInt64 conversion — clamp to [0, 10 years].
            let bounded = timeout.isFinite ? min(max(timeout, 0), 315_360_000) : 315_360_000
            watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
                guard !Task.isCancelled else { return }
                latch.begin(grace: 2)
            }
        }

        // Drains start immediately (the read sources are live from init), so a
        // child that fills a pipe before we get here can never block.
        let stdoutDrain = PipeDrain(handle: stdoutPipe.fileHandleForReading, collector: stdoutCollector)
        let stderrDrain = PipeDrain(handle: stderrPipe.fileHandleForReading, collector: stderrCollector)

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
        // grandchild (a setup script's `helper &` without a redirect) can keep a
        // pipe open indefinitely — bound the wait and END the drains ourselves so a
        // leaked writer can never wedge the caller. (Closing the read handle does
        // NOT do that: see PipeDrain.)
        let drainGuard = Task.detached {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            stdoutDrain.end()
            stderrDrain.end()
        }
        switch onCancellation {
        case .terminateProcess:
            // Cancellation arriving DURING the drain (child already exited, a
            // descendant still holds a pipe) must still signal the group.
            await withTaskCancellationHandler {
                await stdoutDrain.wait()
                await stderrDrain.wait()
            } onCancel: {
                latch.begin(grace: 2)
            }
        case .runToCompletion:
            await stdoutDrain.wait()
            await stderrDrain.wait()
        }
        drainGuard.cancel()

        // Lossy decoding: a kill/timeout can cut the stream mid-multibyte-character,
        // and a strict decode would discard the entire captured output over one
        // dangling prefix — exactly on the failure paths where it is needed most.
        let stdout = String(decoding: stdoutCollector.take(), as: UTF8.self)
        let stderr = String(decoding: stderrCollector.take(), as: UTF8.self)

        switch waitResult.value {
        case .exited(let raw)?:
            // Decode waitpid status the way Foundation.Process reported it: exit code
            // for a normal exit, signal number + .uncaughtSignal for a signalled death.
            let signalNumber = raw & 0x7f
            return CommandResult(
                status: signalNumber != 0 ? signalNumber : (raw >> 8) & 0xff,
                stdout: stdout,
                stderr: stderr,
                terminationReason: signalNumber != 0 ? .uncaughtSignal : .exit
            )
        case .waitFailed(let code)?:
            var diagnostic = "waitpid failed: \(String(cString: strerror(code))) — child exit status unknown"
            if !stderr.isEmpty { diagnostic += "\nchild stderr: \(stderr)" }
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: -1,
                stderr: diagnostic,
                stdout: stdout
            )
        case nil:
            // finish() only runs after record(); reaching here would be a latch bug.
            var diagnostic = "child exit status was never recorded"
            if !stderr.isEmpty { diagnostic += "\nchild stderr: \(stderr)" }
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: -1,
                stderr: diagnostic,
                stdout: stdout
            )
        }
    }

    /// How the reaper's waitpid ended: with the child's raw status, or with a
    /// wait error that makes the real status unknowable.
    private enum WaitResult {
        case exited(Int32)
        case waitFailed(Int32) // errno
    }

    private final class WaitResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: WaitResult?
        func record(_ newResult: WaitResult) {
            lock.lock(); defer { lock.unlock() }
            result = newResult
        }
        var value: WaitResult? {
            lock.lock(); defer { lock.unlock() }
            return result
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
