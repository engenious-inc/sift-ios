import Foundation

/// Physical iOS device or the node's own macOS.
struct Device: TestExecutor {

    let type: TestExecutorType
    let UDID: String
    let nodeName: String
    let ssh: SSHExecutor
    let log: Logging?

    private let config: Config.NodeConfig

    init(type: TestExecutorType, UDID: String, config: Config.NodeConfig, sshFactory: (Config.NodeConfig) -> SSHExecutor, log: Logging?) {
        self.type = type
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

    func ready() async -> Bool {
        guard type == .device else { return true } // macOS: the node itself is the destination
        // Preflight: the device must be visible to Xcode's device stack.
        let command = "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); xcrun xcdevice list"
        guard let output = try? await ssh.run(command).output else {
            log?.warning("\(executorID): xcdevice list failed — assuming device is available")
            return true
        }
        guard output.localizedCaseInsensitiveContains(UDID) else {
            log?.warning("Device \(UDID) not visible on \(nodeName) — ignored for this run")
            return false
        }
        return true
    }

    @discardableResult
    func reset() async -> Bool {
        // No safe generic reset for physical devices / macOS.
        true
    }
}
