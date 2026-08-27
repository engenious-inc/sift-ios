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

    private static let connectTimeoutMsec: UInt = 30_000

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

    // MARK: - Connection

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
            // A black-holed connection must fail an operation, never hang a worker
            // (and with it the whole run) forever.
            session.setOperationTimeout(msec: 15 * 60 * 1000)
            switch policy {
            case .off:
                break
            case .strict:
                try session.verifyHostKey(host: host, port: port, addUnknown: false, knownHostsPath: SSH.knownHostsPath())
            case .acceptNew:
                try session.verifyHostKey(host: host, port: port, addUnknown: true, knownHostsPath: SSH.knownHostsPath())
            }
            if let password {
                try session.authenticate(username: username, password: password)
            } else if let privateKey {
                try session.authenticate(username: username, privateKey: privateKey, publicKey: publicKey, passphrase: passphrase)
            } else {
                try session.authenticateByAgent(username: username)
            }
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
            try requireSession().capture(wrapped)
        }
    }

    // MARK: - File transfer

    func uploadFile(localPath: String, remotePath: String) async throws {
        try await onQueue { [self] in
            try requireSession().openSftp().upload(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath)
        }
    }

    func uploadFile(data: Data, remotePath: String) async throws {
        // Data uploads carry the xctestrun (with injected environment secrets):
        // owner-only, never world-readable.
        let ownerOnly = FilePermissions(owner: [.read, .write], group: [], others: [])
        try await onQueue { [self] in
            try requireSession().openSftp().upload(data: data, remotePath: remotePath, permissions: ownerOnly)
        }
    }

    func downloadFile(remotePath: String, localPath: String) async throws {
        try await onQueue { [self] in
            try requireSession().openSftp().download(remotePath: remotePath, localURL: URL(fileURLWithPath: localPath))
        }
    }

    // MARK: - Background processes

    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle {
        let handle = BackgroundProcessHandle(attemptID: attemptID, directory: "\(workDirectory)/proc/\(attemptID)")
        // A wrapper sh records its own pid, runs the command in its foreground, and
        // writes the exit status atomically. The unique marker lives inside the
        // wrapper's argv, so `ps -o command=` on the recorded pid shows it —
        // that is what makes the later kill provably target our process.
        // Newlines (not ';') separate statements so nothing can be swallowed by
        // a trailing comment inside `command`.
        // `trap '' HUP` (not nohup: macOS nohup needs a controlling console and dies
        // with "can't detach" under a TTY-less sshd exec session) shields the wrapper
        // and every later child from the HUP that sshd sends when the channel closes.
        let inner = """
        # sift-attempt:\(attemptID)
        trap '' HUP
        echo $$ > \(handle.pidPath.shellQuoted)
        ( \(command)
        ) > \(handle.logPath.shellQuoted) 2>&1
        echo $? > \(handle.statusPath.shellQuoted).tmp && mv \(handle.statusPath.shellQuoted).tmp \(handle.statusPath.shellQuoted)
        """
        // Fire-and-forget launcher: no remote wait loop. macOS's bash-3.2 /bin/sh
        // can lose a SIGCHLD race in tight fork loops under sshd and end up
        // blocked in wait4 on the background job — holding the exec channel open
        // for the wrapper's whole lifetime. All waiting happens Swift-side below,
        // each poll on its own short-lived exec channel.
        // `&` must background a SIMPLE command: in `a && b > /dev/null &` the `&`
        // binds to the whole and-list, backgrounding a subshell whose stdout and
        // stderr are still the channel pipes — sshd then holds the exec channel
        // open until the entire background tree dies.
        let launcher = "mkdir -p \(handle.directory.shellQuoted) || exit 1\n" +
            "/bin/sh -c \(inner.shellQuoted) > /dev/null 2>&1 < /dev/null &\n" +
            "exit 0"
        let result = try await run(launcher)
        guard result.status == 0 else {
            throw SSHError.genericError("failed to start background process (status \(result.status)): \(result.output)")
        }
        // Wait for the pid file: its presence proves the wrapper is running with
        // its HUP trap installed (the write happens after the trap), so later
        // channel-close HUPs cannot kill it.
        for _ in 0..<50 {
            let pid = try await run("cat \(handle.pidPath.shellQuoted) 2>/dev/null")
            if pid.status == 0, !pid.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return handle
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SSHError.genericError("background process did not start (no pid recorded in \(handle.pidPath))")
    }

    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32? {
        let result = try await run("cat \(handle.statusPath.shellQuoted) 2>/dev/null")
        guard result.status == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = Int32(trimmed) else { return nil }
        return status
    }

    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async {
        // The recorded pid is the wrapper sh whose argv carries our unique marker.
        // Verify identity before signalling (a recycled pid must never be killed),
        // then TERM the wrapper's children (xcodebuild) and the wrapper itself,
        // escalating to KILL after a bounded wait.
        // The descendant list is snapshotted BEFORE TERM: once the wrapper dies,
        // a TERM-ignoring xcodebuild would be unreachable via the tree walk and
        // would otherwise escape the KILL escalation. The bounded wait between
        // TERM and KILL happens Swift-side (no remote sleep loops — see
        // startBackgroundProcess for the bash-3.2 wait4 hazard).
        // Each tree member is identified by pid AND process start time; both the
        // aliveness probe and the KILL escalation revalidate that identity so a
        // pid recycled during the grace window can never be signalled.
        let termScript = """
        collect_tree() {
            echo "$1"
            for child in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$child"; done
        }
        PID=$(cat \(handle.pidPath.shellQuoted) 2>/dev/null)
        [ -n "$PID" ] || exit 0
        ps -p "$PID" -o command= 2>/dev/null | grep -qF \(marker.shellQuoted) || exit 0
        for p in $(collect_tree "$PID"); do
            START=$(ps -p "$p" -o lstart= 2>/dev/null)
            [ -n "$START" ] || continue
            kill -TERM "$p" 2>/dev/null
            echo "$p|$START"
        done
        exit 0
        """
        guard let termResult = try? await run(termScript) else { return }
        let identities: [(pid: String, start: String)] = termResult.output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let pid = parts[0].trimmingCharacters(in: .whitespaces)
                guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { return nil }
                return (pid, parts[1].trimmingCharacters(in: .whitespaces))
            }
        guard !identities.isEmpty else { return } // marker mismatch or already gone

        // signalMatching(signal): signals only pids whose start time still matches.
        func signalScript(_ signalName: String) -> String {
            var lines = ["ALIVE=0"]
            for identity in identities {
                lines.append("START=$(ps -p \(identity.pid) -o lstart= 2>/dev/null)")
                lines.append("if [ \"$START\" = \(identity.start.shellQuoted) ]; then ALIVE=1; kill -\(signalName) \(identity.pid) 2>/dev/null; fi")
            }
            lines.append("echo \"alive=$ALIVE\"")
            return lines.joined(separator: "\n")
        }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let probe = try? await run(signalScript("0")) else { continue }
            if probe.output.contains("alive=0") { return }
        }
        _ = try? await run(signalScript("KILL"))
    }
}
