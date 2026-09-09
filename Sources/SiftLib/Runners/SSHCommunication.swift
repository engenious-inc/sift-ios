import Foundation

struct SSHCommunication {
    let ssh: SSHExecutor
    private let config: Config.NodeConfig
    private let remoteWorkPath: String
    private let health: HealthSink
    private let log: Logging?

    var nodeName: String { config.name }

    init(config: Config.NodeConfig, remoteWorkPath: String, sshFactory: (Config.NodeConfig) -> SSHExecutor,
         health: HealthSink = HealthSink(), log: Logging?) {
        self.config = config
        self.remoteWorkPath = remoteWorkPath
        self.ssh = sshFactory(config)
        self.health = health
        self.log = log
    }

    func connect() async throws {
        let endpoint = config.transport == .local ? "local" : "\(config.hostValue):\(config.portValue)"
        log?.message(verboseMsg: "Connecting to \(nodeName) (\(endpoint))...")
        try await ssh.connect(
            username: config.usernameValue,
            password: config.password,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            passphrase: config.passphrase
        )
        log?.message(verboseMsg: "\(nodeName): connection established")
    }

    private var remoteZipPath: String { "\(remoteWorkPath)/build.zip" }

    /// Creates the run's remote directory and streams the build archive into it.
    /// Deliberately separate from `unpackBuild`: an upload-concurrency permit
    /// (`maxConcurrentUploads`) must cover only the transfer — extraction needs
    /// no uplink, so the next node's upload should overlap it.
    func uploadBuild(buildPath: String) async throws {
        log?.message(verboseMsg: "Uploading build to \(nodeName)...")
        // umask 077 + explicit chmod: on a shared Mac, other users must not be able
        // to read proprietary bundles, logs, or results. The `.sift` and
        // `.sift/runs` ancestors must be ours and real directories: a symlink or
        // a foreign-writable ancestor would let another local user redirect this
        // run's `rm -rf` (cleanup) somewhere else.
        let siftDirectory = "\(config.deploymentPath)/.sift"
        let runsDirectory = "\(siftDirectory)/runs"
        // Each ancestor is created WITHOUT -p and validated before the next level
        // is touched: `mkdir -p` would silently follow a pre-planted symlink and
        // create (then, on rejection, remove) directories at its target.
        let mkdir = try await ssh.runFast(
            "umask 077; mkdir -p \(config.deploymentPath.shellQuoted) || exit 2; "
            + "for d in \(siftDirectory.shellQuoted) \(runsDirectory.shellQuoted); do "
            + "mkdir \"$d\" 2>/dev/null; "
            + "if [ -L \"$d\" ] || [ ! -d \"$d\" ] || [ ! -O \"$d\" ]; then echo \"refusing $d: not a directory owned by $(id -un) (symlink or foreign owner)\"; exit 2; fi; "
            + "chmod 700 \"$d\" || exit 2; done; "
            + "mkdir -p \(remoteWorkPath.shellQuoted) && chmod -R 700 \(remoteWorkPath.shellQuoted)"
        )
        guard mkdir.status == 0 else {
            throw NSError(domain: "\(nodeName): cannot create remote work directory \(remoteWorkPath): \(mkdir.output)", code: 1)
        }
        // Transfer observability: bytes + duration per node feed the compression-
        // level decision (config `transferCompressionLevel`, README guidance).
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: buildPath)[.size] as? Int64) ?? nil
        let uploadStart = DispatchTime.now()
        try await ssh.uploadFile(localPath: buildPath, remotePath: remoteZipPath)
        let uploadSeconds = Double(DispatchTime.now().uptimeNanoseconds - uploadStart.uptimeNanoseconds) / 1_000_000_000
        let sizeMB = sizeBytes.map { Double($0) / 1_048_576 } ?? 0
        log?.message(verboseMsg: String(format: "%@: build upload %.1f MB in %.1fs (%.1f MB/s)",
                                        nodeName, sizeMB, uploadSeconds, uploadSeconds > 0 ? sizeMB / uploadSeconds : 0))
    }

    /// Unpacks the uploaded archive in place and removes it.
    func unpackBuild() async throws {
        let unzip = try await ssh.run("umask 077; unzip -o -q \(remoteZipPath.shellQuoted) -d \(remoteWorkPath.shellQuoted)")
        guard unzip.status == 0 else {
            throw NSError(domain: "\(nodeName): unzip of uploaded build failed: \(unzip.output)", code: 1)
        }
        _ = try? await ssh.run("rm \(remoteZipPath.shellQuoted)")
        log?.message(verboseMsg: "\(nodeName): build unpacked at \(remoteWorkPath)")
    }

    func saveOnRunner(xctestrun: XCTestRun) async throws -> String {
        let data = try xctestrun.data()
        let xctestrunPath = "\(remoteWorkPath)/\(xctestrun.xctestrunFileName)"
        log?.message(verboseMsg: "Uploading .xctestrun to \(nodeName): \(xctestrun.xctestrunFileName)")
        try await ssh.uploadFile(data: data, remotePath: xctestrunPath)
        return xctestrunPath
    }

    /// Terminates every process this run still owns on the node, then removes
    /// exactly this run's remote directory — nothing else. If the session died,
    /// one bounded reconnect is attempted before giving up; failures are logged
    /// with the exact path left behind, never swallowed silently.
    func cleanup() async {
        var outcomes = await ssh.terminateOwnedProcesses(workDirectory: remoteWorkPath)
        var needsReconnect = outcomes.contains { $0 != .confirmedDead }
        if !needsReconnect {
            // runFast: a black-holed session must surface here within a minute, not
            // stall shutdown for the 15-minute long-command timeout.
            do { _ = try await ssh.runFast("true") } catch { needsReconnect = true }
        }
        var sessionUsable = true
        if needsReconnect {
            // The session may be dead (SSH drop): reconnect once and re-sweep so a
            // launched xcodebuild can never outlive the run unobserved.
            log?.message(verboseMsg: "\(nodeName): cleanup reconnecting to verify process termination")
            do {
                try await connect()
                outcomes = await ssh.terminateOwnedProcesses(workDirectory: remoteWorkPath)
            } catch {
                sessionUsable = false
                log?.error("\(nodeName): cleanup reconnect failed (\(error)) — remote processes may be unverified")
            }
        }
        for case .unverified(let reason) in outcomes {
            log?.error("\(nodeName): could not verify a remote process died during cleanup (\(reason)) — check \(remoteWorkPath)/proc on the node")
            await health.record(RunHealthEvent(kind: .processUnverified, source: nodeName, detail: "\(reason) — check \(remoteWorkPath)/proc"))
        }
        // Removal only over a session that last proved usable, and bounded even
        // then: the session can die between that proof and this command, and the
        // full long-command timeout would wedge shutdown. 5 minutes is roomy for
        // a genuinely large deletion; the no-removal warning below is the honest
        // outcome for a node whose session is gone.
        // The run-ID parent is removed too once it is empty (rmdir refuses a
        // non-empty one — a sibling node entry on the same host may still use it);
        // otherwise every run leaves one empty directory behind on every node.
        // The `.sift` / `.sift/runs` ancestors are re-checked right before the
        // deletion (same rule as uploadBuild): a symlink planted there since would
        // otherwise redirect this `rm -rf` to its target.
        let runDirectory = (remoteWorkPath as NSString).deletingLastPathComponent
        let runsDirectory = (runDirectory as NSString).deletingLastPathComponent
        let siftDirectory = (runsDirectory as NSString).deletingLastPathComponent
        let removal = sessionUsable
            ? (try? await ssh.runBounded(
                "for d in \(siftDirectory.shellQuoted) \(runsDirectory.shellQuoted) \(runDirectory.shellQuoted); do "
                + "if [ -L \"$d\" ]; then echo \"refusing cleanup: $d is a symlink\"; exit 2; fi; done; "
                + "rm -rf \(remoteWorkPath.shellQuoted); status=$?; rmdir \(runDirectory.shellQuoted) 2>/dev/null; exit $status",
                timeoutSeconds: 300
            ))
            : nil
        if removal == nil || removal?.status != 0 {
            log?.warning("\(nodeName): remote cleanup incomplete — \(remoteWorkPath) may remain on the node")
            await health.record(RunHealthEvent(kind: .cleanupIncomplete, source: nodeName, detail: "\(remoteWorkPath) may remain on the node"))
        }
    }
}
