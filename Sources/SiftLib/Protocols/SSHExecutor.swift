import Foundation

/// Bookkeeping for a remote process Sift owns: pid/status/log files inside a
/// run-scoped directory, plus a unique marker used to verify process identity
/// before any kill signal is sent.
public struct BackgroundProcessHandle: Sendable {
    public let attemptID: String
    public let directory: String

    public var pidPath: String { "\(directory)/pid" }
    public var statusPath: String { "\(directory)/status" }
    public var logPath: String { "\(directory)/log" }

    public init(attemptID: String, directory: String) {
        self.attemptID = attemptID
        self.directory = directory
    }
}

public protocol SSHExecutor: ShellExecutor {
    /// Stores connection parameters only — no I/O until `connect`.
    init(
        host: String,
        port: Int32,
        arch: Config.NodeConfig.Arch?,
        hostKeyVerification: Config.NodeConfig.HostKeyVerification
    )

    func connect(
        username: String,
        password: String?,
        privateKey: String?,
        publicKey: String?,
        passphrase: String?
    ) async throws

    func uploadFile(localPath: String, remotePath: String) async throws
    func uploadFile(data: Data, remotePath: String) async throws
    func downloadFile(remotePath: String, localPath: String) async throws

    /// Launches `command` detached on the node; its pid, exit status, and combined
    /// output are recorded under `workDirectory/proc/<attemptID>/`.
    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle

    /// nil while the process is still running; the exit status once it finished.
    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32?

    /// TERM → bounded wait → KILL. Only signals a pid whose command line contains
    /// `marker`, so a recycled pid can never be killed by mistake.
    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async
}
