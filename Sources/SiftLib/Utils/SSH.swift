import Foundation
import Shout

/// libssh2-backed SSHExecutor. Every libssh2 call is confined to one serial DispatchQueue
/// (libssh2 sessions are not thread-safe), bridged to async callers with continuations so
/// no Swift-concurrency cooperative thread is ever blocked on network I/O.
final class SSH: SSHExecutor, @unchecked Sendable {
    private let queue: DispatchQueue
    private let host: String
    private let port: Int32
    private let arch: Config.NodeConfig.Arch?
    private let hostKeyVerification: Config.NodeConfig.HostKeyVerification
    private var ssh: Shout.SSH?
    /// One cached SFTP channel per connection (opening one per transfer costs a
    /// round-trip each). Queue-confined; discarded on any transfer error.
    private var cachedSftp: SFTP?

    private static let connectTimeoutMsec: UInt = 30_000
    /// Short commands and status polls: a black-holed connection must fail fast,
    /// never stall a worker behind a 15-minute cap.
    private static let commandTimeoutMsec = 60_000
    /// User scripts and remote zips can legitimately run long.
    private static let longCommandTimeoutMsec = 15 * 60 * 1000
    /// Bulk SFTP transfers (multi-GB build archives).
    private static let transferTimeoutMsec = 15 * 60 * 1000

    init(
        host: String,
        port: Int32,
        arch: Config.NodeConfig.Arch?,
        hostKeyVerification: Config.NodeConfig.HostKeyVerification
    ) {
        self.host = host
        self.port = port
        self.arch = arch
        self.hostKeyVerification = hostKeyVerification
        self.queue = DispatchQueue(label: "sift.ssh.\(host):\(port)")
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requireSession() throws -> Shout.SSH {
        guard let ssh else {
            throw SSHError.genericError("SSH session to \(host):\(port) is not connected")
        }
        return ssh
    }

    /// Thread-safe one-way flag bridging task cancellation into queue-confined loops.
    private final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var aborted = false
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return aborted
        }
        func set() {
            lock.lock(); defer { lock.unlock() }
            aborted = true
        }
    }

    // MARK: - Connection

    /// Serializes known_hosts read-modify-write across every concurrently
    /// connecting node in this process — parallel TOFU writers must never lose
    /// each other's trusted entries.
    private static let knownHostsLock = NSLock()

    func connect(
        username: String,
        password: String?,
        privateKey: String?,
        publicKey: String?,
        passphrase: String?
    ) async throws {
        let host = self.host, port = self.port, policy = self.hostKeyVerification
        try await onQueue { [self] in
            let session = try Shout.SSH(host: host, port: port, timeout: SSH.connectTimeoutMsec)
            session.setOperationTimeout(msec: SSH.commandTimeoutMsec)
            switch policy {
            case .off:
                break
            case .strict:
                SSH.knownHostsLock.lock()
                defer { SSH.knownHostsLock.unlock() }
                try session.verifyHostKey(host: host, port: port, addUnknown: false, knownHostsPath: SSH.knownHostsPath())
            case .acceptNew:
                SSH.knownHostsLock.lock()
                defer { SSH.knownHostsLock.unlock() }
                try session.verifyHostKey(host: host, port: port, addUnknown: true, knownHostsPath: SSH.knownHostsPath())
            }
            if let password {
                try session.authenticate(username: username, password: password)
            } else if let privateKey {
                try session.authenticate(username: username, privateKey: privateKey, publicKey: publicKey, passphrase: passphrase)
            } else {
                try session.authenticateByAgent(username: username)
            }
            // Replacing the session orphans any cached SFTP channel — it belongs to
            // the OLD transport and would fail (or hang) the first post-reconnect
            // transfer, losing an otherwise salvageable result.
            self.cachedSftp = nil
            self.ssh = session
        }
    }

    private static func knownHostsPath() throws -> String {
        let directory = NSHomeDirectory() + "/.sift"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory + "/known_hosts"
    }

    // MARK: - Commands

    @discardableResult
    func run(_ command: String) async throws -> (status: Int32, output: String) {
        // User scripts and remote zip/unzip can run long; polls use runFast.
        try await run(command, opTimeoutMsec: SSH.longCommandTimeoutMsec)
    }

    /// Short-timeout variant for internal probes (status polls, pid reads) where a
    /// black-holed connection must surface within a minute.
    @discardableResult
    func runFast(_ command: String) async throws -> (status: Int32, output: String) {
        try await run(command, opTimeoutMsec: SSH.commandTimeoutMsec)
    }

    private func run(_ command: String, opTimeoutMsec: Int) async throws -> (status: Int32, output: String) {
        // Always execute through /bin/sh: sshd hands the command to the user's
        // login shell, and zsh's parsing differs from sh in ways that silently
        // break scripts (no implicit word splitting of unquoted expansions).
        let wrapped: String
        if let arch {
            wrapped = "arch -\(arch.rawValue) /bin/sh -c \(command.shellQuoted)"
        } else {
            wrapped = "/bin/sh -c \(command.shellQuoted)"
        }
        return try await onQueue { [self] in
            let session = try requireSession()
            session.setOperationTimeout(msec: opTimeoutMsec)
            defer { session.setOperationTimeout(msec: SSH.commandTimeoutMsec) }
            // 1 MiB tail: a noisy setup script cannot balloon controller memory.
            return try session.capture(wrapped, outputTailLimit: 1_048_576)
        }
    }

    // MARK: - File transfer

    /// Cached-or-fresh SFTP channel. MUST be called on the serial queue.
    private func sftpSession() throws -> SFTP {
        if let cachedSftp { return cachedSftp }
        let sftp = try requireSession().openSftp()
        cachedSftp = sftp
        return sftp
    }

    /// Runs one transfer on the serial queue with the transfer timeout, reusing the
    /// cached SFTP channel and discarding it on any error (a broken channel must
    /// never poison later transfers). A failure on a CACHED channel gets ONE retry
    /// on a freshly opened channel — a channel gone stale between transfers must
    /// not fail an otherwise salvageable download.
    private func transfer<T: Sendable>(
        _ body: @escaping @Sendable (SFTP) throws -> T
    ) async throws -> T {
        try await onQueue { [self] in
            let session = try requireSession()
            session.setOperationTimeout(msec: SSH.transferTimeoutMsec)
            defer { session.setOperationTimeout(msec: SSH.commandTimeoutMsec) }
            let usedCachedChannel = cachedSftp != nil
            do {
                return try body(try sftpSession())
            } catch {
                cachedSftp = nil
                guard usedCachedChannel else { throw error }
                do {
                    return try body(try sftpSession())
                } catch {
                    cachedSftp = nil
                    throw error
                }
            }
        }
    }

    /// Bridges task cancellation to the queue-confined transfer loop: the transfer
    /// aborts within one chunk, releasing the serial queue for teardown commands.
    private func withTransferAbort<T: Sendable>(
        _ body: @escaping @Sendable (SFTP, _ shouldAbort: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let flag = AbortFlag()
        return try await withTaskCancellationHandler {
            try await transfer { sftp in
                try body(sftp) { flag.value }
            }
        } onCancel: {
            flag.set()
        }
    }

    func uploadFile(localPath: String, remotePath: String) async throws {
        // Owner-only: uploaded builds are proprietary binaries on a possibly-shared Mac.
        let ownerOnly = FilePermissions(owner: [.read, .write], group: [], others: [])
        try await withTransferAbort { sftp, shouldAbort in
            try sftp.upload(
                localURL: URL(fileURLWithPath: localPath),
                remotePath: remotePath,
                permissions: ownerOnly,
                shouldAbort: shouldAbort
            )
        }
    }

    func uploadFile(data: Data, remotePath: String) async throws {
        // Data uploads carry the xctestrun (with injected environment secrets):
        // owner-only, never world-readable.
        let ownerOnly = FilePermissions(owner: [.read, .write], group: [], others: [])
        try await withTransferAbort { sftp, shouldAbort in
            _ = shouldAbort // small payloads: abort granularity is the whole write
            try sftp.upload(data: data, remotePath: remotePath, permissions: ownerOnly)
        }
    }

    func downloadFile(remotePath: String, localPath: String, abortOnCancellation: Bool) async throws {
        if abortOnCancellation {
            try await withTransferAbort { sftp, shouldAbort in
                try sftp.download(
                    remotePath: remotePath,
                    localURL: URL(fileURLWithPath: localPath),
                    shouldAbort: shouldAbort
                )
            }
        } else {
            // Salvage mode: result bundles downloaded after cancellation.
            try await transfer { sftp in
                try sftp.download(
                    remotePath: remotePath,
                    localURL: URL(fileURLWithPath: localPath),
                    shouldAbort: nil
                )
            }
        }
    }

    // MARK: - Background processes

    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle {
        let handle = BackgroundProcessHandle(attemptID: attemptID, directory: "\(workDirectory)/proc/\(attemptID)")
        // Shared owned-process contract — see ProcessScripts for the full rationale
        // (marker-in-argv identity, HUP shield, atomic status write, channel-safe &).
        let launcher = ProcessScripts.launcher(handle: handle, command: command)
        let result = try await runFast(launcher)
        guard result.status == 0 else {
            throw SSHError.genericError("failed to start background process (status \(result.status)): \(result.output)")
        }
        // From here the wrapper may already be running: any failure below must
        // terminate it before rethrowing, or a cancellation/drop during this wait
        // orphans a launched xcodebuild.
        do {
            // Wait for the pid file: its presence proves the wrapper is running with
            // its HUP trap installed (the write happens after the trap), so later
            // channel-close HUPs cannot kill it. The sleep is uncancellable so a
            // Ctrl-C during launch still observes the pid and owns the process.
            for _ in 0..<50 {
                let pid = try await runFast("cat \(handle.pidPath.shellQuoted) 2>/dev/null")
                if pid.status == 0, !pid.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return handle
                }
                await CommandLineExecutor.uncancellableSleep(seconds: 0.1)
            }
            throw SSHError.genericError("background process did not start (no pid recorded in \(handle.pidPath))")
        } catch {
            _ = await terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            throw error
        }
    }

    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32? {
        let result = try await runFast("cat \(handle.statusPath.shellQuoted) 2>/dev/null")
        guard result.status == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = Int32(trimmed) else { return nil }
        return status
    }

    @discardableResult
    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async -> TerminationOutcome {
        // The recorded pid is the wrapper sh whose argv carries our unique marker.
        // Verify identity before signalling (a recycled pid must never be killed),
        // then TERM the wrapper's children (xcodebuild) and the wrapper itself,
        // escalating to KILL after a bounded wait.
        // The descendant list is snapshotted BEFORE TERM: once the wrapper dies,
        // a TERM-ignoring xcodebuild would be unreachable via the tree walk and
        // would otherwise escape the KILL escalation. The bounded wait between
        // TERM and KILL happens Swift-side (no remote sleep loops — see
        // startBackgroundProcess for the bash-3.2 wait4 hazard) and is UNCANCELLABLE:
        // a Ctrl-C must not collapse the TERM grace into an instant KILL.
        // Each tree member is identified by pid AND process start time; both the
        // aliveness probe and the KILL escalation revalidate that identity so a
        // pid recycled during the grace window can never be signalled.
        let termScript = ProcessScripts.terminate(handle: handle, marker: marker)
        guard let termResult = try? await runFast(termScript) else {
            return .unverified("terminate command could not run (SSH session unavailable)")
        }
        if termResult.output.contains("sift-no-pid") || termResult.output.contains("sift-no-match") {
            return .notFound
        }
        let identities = ProcessScripts.parseIdentities(fromTermOutput: termResult.output)
        guard !identities.isEmpty else { return .notFound } // already gone

        func signalScript(_ signalName: String) -> String {
            ProcessScripts.signal(signalName, identities: identities)
        }
        for _ in 0..<10 {
            await CommandLineExecutor.uncancellableSleep(seconds: 1)
            guard let probe = try? await runFast(signalScript("0")) else { continue }
            if probe.output.contains("alive=0") { return .confirmedDead }
        }
        guard let killResult = try? await runFast(signalScript("KILL")) else {
            return .unverified("KILL escalation could not run (SSH session unavailable)")
        }
        await CommandLineExecutor.uncancellableSleep(seconds: 1)
        guard let finalProbe = try? await runFast(signalScript("0")) else {
            return .unverified("post-KILL probe could not run")
        }
        _ = killResult
        return finalProbe.output.contains("alive=0") ? .confirmedDead : .unverified("process still alive after KILL")
    }

    func terminateOwnedProcesses(workDirectory: String) async -> [TerminationOutcome] {
        let procDirectory = "\(workDirectory)/proc"
        guard let listing = try? await runFast("ls \(procDirectory.shellQuoted) 2>/dev/null"), listing.status == 0 else {
            return []
        }
        let attemptIDs = listing.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var outcomes: [TerminationOutcome] = []
        for attemptID in attemptIDs {
            let handle = BackgroundProcessHandle(attemptID: attemptID, directory: "\(procDirectory)/\(attemptID)")
            let outcome = await terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            if outcome != .notFound {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }
}
