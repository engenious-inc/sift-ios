import Foundation

struct SSHCommunication: Communication {
    private let ssh: SSHExecutor
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
        log?.message(verboseMsg: "Connecting to \(nodeName) (\(config.host):\(config.port))...")
        try await ssh.connect(
            username: config.username,
            password: config.password,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            passphrase: config.passphrase
        )
        log?.message(verboseMsg: "\(nodeName): connection established")
    }

    func getBuildOnRunner(buildPath: String) async throws {
        log?.message(verboseMsg: "Uploading build to \(nodeName)...")
        let remoteZipPath = "\(remoteWorkPath)/build.zip"
        // umask 077 + explicit chmod: on a shared Mac, other users must not be able
        // to read proprietary bundles, logs, or results.
        let mkdir = try await ssh.run("umask 077; mkdir -p \(remoteWorkPath.shellQuoted) && chmod -R 700 \(remoteWorkPath.shellQuoted)")
        guard mkdir.status == 0 else {
            throw NSError(domain: "\(nodeName): cannot create remote work directory \(remoteWorkPath): \(mkdir.output)", code: 1)
        }
        try await ssh.uploadFile(localPath: buildPath, remotePath: remoteZipPath)
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

    func executeOnRunner(command: String) async throws -> (status: Int32, output: String) {
        try await ssh.run(command)
    }

    /// Terminates every process this run still owns on the node, then removes
    /// exactly this run's remote directory — nothing else. If the session died,
    /// one bounded reconnect is attempted before giving up; failures are logged
    /// with the exact path left behind, never swallowed silently.
    func cleanup() async {
        var outcomes = await ssh.terminateOwnedProcesses(workDirectory: remoteWorkPath)
        var needsReconnect = outcomes.contains { $0 != .confirmedDead }
        if !needsReconnect {
            do { _ = try await ssh.run("true") } catch { needsReconnect = true }
        }
        if needsReconnect {
            // The session may be dead (SSH drop): reconnect once and re-sweep so a
            // launched xcodebuild can never outlive the run unobserved.
            log?.message(verboseMsg: "\(nodeName): cleanup reconnecting to verify process termination")
            do {
                try await connect()
                outcomes = await ssh.terminateOwnedProcesses(workDirectory: remoteWorkPath)
            } catch {
                log?.error("\(nodeName): cleanup reconnect failed (\(error)) — remote processes may be unverified")
            }
        }
        for case .unverified(let reason) in outcomes {
            log?.error("\(nodeName): could not verify a remote process died during cleanup (\(reason)) — check \(remoteWorkPath)/proc on the node")
            await health.record(RunHealthEvent(kind: .processUnverified, source: nodeName, detail: "\(reason) — check \(remoteWorkPath)/proc"))
        }
        let removal = try? await ssh.run("rm -rf \(remoteWorkPath.shellQuoted)")
        if removal == nil || removal?.status != 0 {
            log?.warning("\(nodeName): remote cleanup incomplete — \(remoteWorkPath) may remain on the node")
            await health.record(RunHealthEvent(kind: .cleanupIncomplete, source: nodeName, detail: "\(remoteWorkPath) may remain on the node"))
        }
    }
}
