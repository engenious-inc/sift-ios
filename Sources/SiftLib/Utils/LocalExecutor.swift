import Foundation

/// Local no-SSH transport: the node IS this machine. Implements the full
/// `SSHExecutor` contract with local primitives — same owned-background-process
/// scripts (ProcessScripts), same pid/status/log layout, same TERM→KILL identity
/// checks — so Node/Xcodebuild/cleanup logic is byte-identical across transports.
/// Crucially, processes run inside the user's login session: macOS UI tests reach
/// `testmanagerd`, which an SSH exec session may not.
final class LocalExecutor: SSHExecutor, @unchecked Sendable {

    private let arch: Config.NodeConfig.Arch?
    private let shell = Run()

    init(
        host: String,
        port: Int32,
        arch: Config.NodeConfig.Arch?,
        hostKeyVerification: Config.NodeConfig.HostKeyVerification
    ) {
        self.arch = arch
    }

    /// No connection to make; credentials are ignored.
    func connect(username: String, password: String?, privateKey: String?, publicKey: String?, passphrase: String?) async throws {}

    @discardableResult
    func run(_ command: String) async throws -> (status: Int32, output: String) {
        // Mirrors the SSH transport: /bin/sh semantics, and the command must run to
        // completion even on a cancelled task (teardown/terminate sequences execute
        // during cancellation), bounded so nothing can hang shutdown forever.
        let wrapped = arch.map { "arch -\($0.rawValue) /bin/sh -c \(command.shellQuoted)" }
            ?? "/bin/sh -c \(command.shellQuoted)"
        let result = try await CommandLineExecutor.launch(
            executable: "/bin/sh", arguments: ["-c", wrapped],
            onCancellation: .runToCompletion, timeout: 900
        )
        return (result.status, result.stdout)
    }

    func uploadFile(localPath: String, remotePath: String) async throws {
        try copy(from: localPath, to: remotePath)
    }

    func uploadFile(data: Data, remotePath: String) async throws {
        try FileManager.default.createDirectory(
            atPath: (remotePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.createFile(atPath: remotePath, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw XCTestRunError("cannot write \(remotePath)")
        }
    }

    func downloadFile(remotePath: String, localPath: String, abortOnCancellation: Bool) async throws {
        try copy(from: remotePath, to: localPath)
    }

    private func copy(from source: String, to destination: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: source, toPath: destination)
    }

    // MARK: - Owned background processes (shared contract)

    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle {
        let handle = BackgroundProcessHandle(attemptID: attemptID, directory: "\(workDirectory)/proc/\(attemptID)")
        let result = try await run(ProcessScripts.launcher(handle: handle, command: command))
        guard result.status == 0 else {
            throw XCTestRunError("failed to start background process (status \(result.status)): \(result.output)")
        }
        do {
            for _ in 0..<50 {
                if let pid = FileManager.default.contents(atPath: handle.pidPath),
                   !String(decoding: pid, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return handle
                }
                await CommandLineExecutor.uncancellableSleep(seconds: 0.1)
            }
            throw XCTestRunError("background process did not start (no pid recorded in \(handle.pidPath))")
        } catch {
            _ = await terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            throw error
        }
    }

    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32? {
        guard let data = FileManager.default.contents(atPath: handle.statusPath) else { return nil }
        return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async -> TerminationOutcome {
        guard let termResult = try? await run(ProcessScripts.terminate(handle: handle, marker: marker)) else {
            return .unverified("terminate script could not run")
        }
        if termResult.output.contains("sift-no-pid") || termResult.output.contains("sift-no-match") {
            return .notFound
        }
        let identities = ProcessScripts.parseIdentities(fromTermOutput: termResult.output)
        guard !identities.isEmpty else { return .notFound }

        for _ in 0..<10 {
            await CommandLineExecutor.uncancellableSleep(seconds: 1)
            guard let probe = try? await run(ProcessScripts.signal("0", identities: identities)) else { continue }
            if probe.output.contains("alive=0") { return .confirmedDead }
        }
        _ = try? await run(ProcessScripts.signal("KILL", identities: identities))
        await CommandLineExecutor.uncancellableSleep(seconds: 1)
        guard let finalProbe = try? await run(ProcessScripts.signal("0", identities: identities)) else {
            return .unverified("post-KILL probe could not run")
        }
        return finalProbe.output.contains("alive=0") ? .confirmedDead : .unverified("process still alive after KILL")
    }

    func terminateOwnedProcesses(workDirectory: String) async -> [TerminationOutcome] {
        let procDirectory = "\(workDirectory)/proc"
        guard let attemptIDs = try? FileManager.default.contentsOfDirectory(atPath: procDirectory) else { return [] }
        var outcomes: [TerminationOutcome] = []
        for attemptID in attemptIDs where !attemptID.hasPrefix(".") {
            let handle = BackgroundProcessHandle(attemptID: attemptID, directory: "\(procDirectory)/\(attemptID)")
            let outcome = await terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            if outcome != .notFound {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }
}
