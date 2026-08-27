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
        let wrapped = wrapForArch(command)
        return try await onQueue { [self] in
            try requireSession().capture(wrapped)
        }
    }

    private func wrapForArch(_ command: String) -> String {
        guard let arch else { return command }
        return "arch -\(arch.rawValue) /bin/sh -c \(command.shellQuoted)"
    }

    // MARK: - File transfer

    func uploadFile(localPath: String, remotePath: String) async throws {
        try await onQueue { [self] in
            try requireSession().openSftp().upload(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath)
        }
    }

    func uploadFile(data: Data, remotePath: String) async throws {
        try await onQueue { [self] in
            try requireSession().openSftp().upload(data: data, remotePath: remotePath)
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
        // The launcher waits for the pid file before returning: until the wrapper's
        // trap is installed it is killable by that channel-close HUP — returning
        // only once the pid exists closes the race.
        let launcher = "mkdir -p \(handle.directory.shellQuoted) && " +
            "/bin/sh -c \(inner.shellQuoted) > /dev/null 2>&1 < /dev/null &\n" +
            "for i in $(seq 1 100); do [ -f \(handle.pidPath.shellQuoted) ] && exit 0; sleep 0.1; done\n" +
            "exit 1"
        let result = try await run(launcher)
        guard result.status == 0 else {
            throw SSHError.genericError("failed to start background process (status \(result.status)): \(result.output)")
        }
        return handle
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
        let script = """
        kill_tree() {
            for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child" "$2"; done
            kill "-$2" "$1" 2>/dev/null
        }
        PID=$(cat \(handle.pidPath.shellQuoted) 2>/dev/null)
        [ -n "$PID" ] || exit 0
        ps -p "$PID" -o command= 2>/dev/null | grep -qF \(marker.shellQuoted) || exit 0
        kill_tree "$PID" TERM
        for i in 1 2 3 4 5 6 7 8 9 10; do
            ps -p "$PID" > /dev/null 2>&1 || exit 0
            sleep 1
        done
        kill_tree "$PID" KILL
        exit 0
        """
        _ = try? await run(script)
    }
}
