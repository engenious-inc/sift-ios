import Foundation

struct Simulator: TestExecutor {

    let type: TestExecutorType = .simulator
    let UDID: String
    let nodeName: String
    let ssh: SSHExecutor
    let log: Logging?

    private let config: Config.NodeConfig

    init(UDID: String, config: Config.NodeConfig, sshFactory: (Config.NodeConfig) -> SSHExecutor, log: Logging?) {
        self.UDID = UDID
        self.config = config
        self.nodeName = config.name
        self.ssh = sshFactory(config)
        self.log = log
    }

    func connect() async throws {
        log?.message(verboseMsg: "\(executorID): opening connection")
        try await ssh.connect(
            username: config.username,
            password: config.password,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            passphrase: config.passphrase
        )
        log?.message(verboseMsg: "\(executorID): connection established")
    }

    private var developerDirExport: String {
        "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); "
    }

    func ready() async -> Bool {
        log?.message(verboseMsg: "checking simulator \(UDID)")
        guard let output = try? await ssh.run(developerDirExport + "xcrun simctl list devices").output else {
            log?.error("\(executorID): can't run simctl list")
            return false
        }
        // Case-insensitive: simctl prints uppercase UDIDs, configs may differ.
        guard let line = output.components(separatedBy: "\n").first(where: { $0.localizedCaseInsensitiveContains(UDID) }) else {
            log?.warning("Simulator \(UDID) not found on \(nodeName) — ignored for this run")
            return false
        }
        if !line.contains("(Booted)") {
            log?.message("\(executorID): simulator not booted — booting")
            return await reset()
        }
        return true
    }

    @discardableResult
    func reset() async -> Bool {
        log?.message(verboseMsg: "\(executorID): resetting simulator")
        let quotedUDID = UDID.shellQuoted
        // shutdown/erase may legitimately fail when already shut down/clean — boot must succeed.
        _ = try? await ssh.run(developerDirExport + "xcrun simctl shutdown \(quotedUDID)")
        _ = try? await ssh.run(developerDirExport + "xcrun simctl erase \(quotedUDID)")
        guard let boot = try? await ssh.run(developerDirExport + "xcrun simctl boot \(quotedUDID)"),
              boot.status == 0 else {
            log?.error("\(executorID): simulator boot failed")
            return false
        }
        // Wait for boot to actually complete instead of a fixed sleep.
        guard let bootstatus = try? await ssh.run(developerDirExport + "xcrun simctl bootstatus \(quotedUDID) -b"),
              bootstatus.status == 0 else {
            log?.error("\(executorID): simulator did not finish booting")
            return false
        }
        log?.message(verboseMsg: "\(executorID): simulator reset complete")
        return true
    }
}
