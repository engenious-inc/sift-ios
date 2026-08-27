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
            username: config.usernameValue,
            password: config.password,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            passphrase: config.passphrase
        )
        log?.message(verboseMsg: "\(executorID): connection established")
    }

    func ready() async -> Bool {
        guard type == .device else { return await macReady() }
        // Preflight: the device must be visible and available to Xcode's device
        // stack. A failed check is a failed check — never "assume available".
        let command = "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); xcrun xcdevice list"
        guard let result = try? await ssh.run(command), result.status == 0 else {
            log?.warning("\(executorID): xcdevice list failed — device ignored for this run")
            return false
        }
        guard let entry = deviceEntry(inXCDeviceOutput: result.output) else {
            log?.warning("Device \(UDID) not visible on \(nodeName) — ignored for this run")
            return false
        }
        if entry["available"] as? Bool == false {
            let reason = (entry["error"] as? [String: Any])?["description"] as? String ?? "unavailable"
            log?.warning("Device \(UDID) on \(nodeName) is not available (\(reason)) — ignored for this run")
            return false
        }
        return true
    }

    /// macOS destinations get a light preflight too — the node must be a reachable
    /// Mac with a working shell, never "assume available".
    private func macReady() async -> Bool {
        guard let result = try? await ssh.run("sw_vers -productVersion"), result.status == 0 else {
            log?.warning("\(executorID): macOS preflight failed (sw_vers) — ignored for this run")
            return false
        }
        return true
    }

    private func deviceEntry(inXCDeviceOutput output: String) -> [String: Any]? {
        // xcdevice may prefix warnings (which can themselves contain '[', e.g.
        // "[MT] ...") before the JSON — try every '[' candidate until one parses
        // as the device array.
        for index in output.indices where output[index] == "[" {
            guard let data = String(output[index...]).data(using: .utf8) else { continue }
            if let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return entries.first { ($0["identifier"] as? String)?.caseInsensitiveCompare(UDID) == .orderedSame }
            }
        }
        return nil
    }

    @discardableResult
    func reset() async -> Bool {
        // No safe generic reset for physical devices / macOS.
        true
    }
}
