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
    /// `abortOnCancellation: false` = salvage mode: after Ctrl-C the result bundle
    /// download IS the partial report — it must complete despite cancellation.
    func downloadFile(remotePath: String, localPath: String, abortOnCancellation: Bool) async throws

    /// Launches `command` detached on the node; its pid, exit status, and combined
    /// output are recorded under `workDirectory/proc/<attemptID>/`.
    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle

    /// nil while the process is still running; the exit status once it finished.
    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32?

    /// TERM → bounded wait → KILL. Only signals a pid whose command line contains
    /// `marker`, so a recycled pid can never be killed by mistake.
    @discardableResult
    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async -> TerminationOutcome

    /// Sweeps `workDirectory/proc/*/pid` and terminates every process that still
    /// carries a `sift-attempt:` marker — the cleanup-time safety net for handles
    /// lost to SSH drops or cancellation.
    func terminateOwnedProcesses(workDirectory: String) async -> [TerminationOutcome]
}

extension SSHExecutor {
    func downloadFile(remotePath: String, localPath: String) async throws {
        try await downloadFile(remotePath: remotePath, localPath: localPath, abortOnCancellation: true)
    }
}

/// Result of a termination attempt — cleanup must distinguish "confirmed dead"
/// from "could not verify" (dead session, probe failure).
public enum TerminationOutcome: Sendable, Equatable {
    /// Process (and its snapshotted descendants) verified gone.
    case confirmedDead
    /// No matching live process: never started, already exited, or marker mismatch.
    case notFound
    /// Termination could not be verified — the reason says why.
    case unverified(String)
}
