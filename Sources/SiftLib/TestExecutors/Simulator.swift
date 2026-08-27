import Foundation

/// A user-provided simulator. Sift never erases it: readiness boots it when needed
/// (recording that fact), recovery is shutdown+boot, and `finish()` restores the
/// boot state Sift found. Erase is reserved for Sift-owned clones (auto-provisioning).
actor Simulator: TestExecutor {

    nonisolated let type: TestExecutorType = .simulator
    nonisolated let UDID: String
    nonisolated let nodeName: String
    nonisolated let ssh: SSHExecutor
    nonisolated let log: Logging?

    private let config: Config.NodeConfig
    /// True for Sift-created clones (auto-provisioning): the ONLY simulators Sift
    /// may erase during recovery; deleted by the node when the run ends.
    nonisolated let siftOwned: Bool
    /// True when Sift booted this simulator (it was shut down when the run began).
    private var bootedBySift = false

    init(UDID: String, config: Config.NodeConfig, sshFactory: (Config.NodeConfig) -> SSHExecutor,
         siftOwned: Bool = false, log: Logging?) {
        self.UDID = UDID
        self.config = config
        self.nodeName = config.name
        self.ssh = sshFactory(config)
        self.siftOwned = siftOwned
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

    private nonisolated var developerDirExport: String {
        "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); "
    }

    private struct SimctlDeviceList: Codable {
        struct Device: Codable {
            let udid: String
            let state: String
            let isAvailable: Bool?
        }
        let devices: [String: [Device]]
    }

    /// The device's entry from structured `simctl list devices --json` — never a
    /// substring match over human-readable output.
    private func deviceEntry() async -> SimctlDeviceList.Device? {
        guard let result = try? await ssh.run(developerDirExport + "xcrun simctl list devices --json"),
              result.status == 0,
              let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimctlDeviceList.self, from: data) else {
            log?.error("\(executorID): `simctl list devices --json` failed")
            return nil
        }
        return list.devices.values
            .joined()
            .first { $0.udid.caseInsensitiveCompare(UDID) == .orderedSame }
    }

    func ready() async -> Bool {
        log?.message(verboseMsg: "checking simulator \(UDID)")
        guard let device = await deviceEntry() else {
            log?.warning("Simulator \(UDID) not found on \(nodeName) — ignored for this run")
            return false
        }
        guard device.isAvailable ?? false else {
            log?.warning("Simulator \(UDID) on \(nodeName) is unavailable — ignored for this run")
            return false
        }
        if device.state == "Booted" {
            return true
        }
        log?.message("\(executorID): simulator not booted — booting")
        guard await boot() else { return false }
        bootedBySift = true
        return true
    }

    /// Boot (no erase) and wait for it to complete.
    private func boot() async -> Bool {
        let quotedUDID = UDID.shellQuoted
        guard let boot = try? await ssh.run(developerDirExport + "xcrun simctl boot \(quotedUDID)"),
              boot.status == 0 else {
            log?.error("\(executorID): simulator boot failed")
            return false
        }
        guard let bootstatus = try? await ssh.run(developerDirExport + "xcrun simctl bootstatus \(quotedUDID) -b"),
              bootstatus.status == 0 else {
            log?.error("\(executorID): simulator did not finish booting")
            return false
        }
        return true
    }

    /// Recovery after an unhealthy chunk: shutdown + boot. A USER simulator is
    /// never erased; a Sift-owned clone is erased for a maximally clean retry.
    @discardableResult
    func reset() async -> Bool {
        log?.message(verboseMsg: "\(executorID): restarting simulator")
        _ = try? await ssh.run(developerDirExport + "xcrun simctl shutdown \(UDID.shellQuoted)")
        if siftOwned {
            _ = try? await ssh.run(developerDirExport + "xcrun simctl erase \(UDID.shellQuoted)")
        }
        return await boot()
    }

    /// Restores the boot state Sift found: shuts the simulator down only if Sift
    /// booted it for this run.
    func finish() async {
        guard bootedBySift else { return }
        log?.message(verboseMsg: "\(executorID): shutting simulator back down (Sift booted it)")
        _ = try? await ssh.run(developerDirExport + "xcrun simctl shutdown \(UDID.shellQuoted)")
    }
}
