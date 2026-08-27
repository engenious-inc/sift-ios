import Foundation

/// Preflight for a config: verifies everything a run needs — controller tooling,
/// the artifact, the output directory, and every node/executor — and prints one
/// ✔/✖ line per check. Returns false when any required check fails.
public struct Doctor {

    private let config: Config
    private let dependencies: ControllerDependencies
    private var failures = 0

    public init(config: Config, dependencies: ControllerDependencies = ControllerDependencies()) {
        self.config = config
        self.dependencies = dependencies
    }

    private mutating func report(_ ok: Bool, _ label: String, _ detail: String) {
        if !ok { failures += 1 }
        print("\(ok ? "✔" : "✖") \(label): \(detail)")
    }

    public mutating func run() async -> Bool {
        await checkController()
        await checkArtifact()
        checkOutputDirectory()
        for node in config.nodes {
            await check(node: node)
        }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }

    // MARK: - Controller

    private mutating func checkController() async {
        if let version = try? await dependencies.localShell.runChecked("/usr/bin/xcodebuild", ["-version"]) {
            let line = version.stdout.components(separatedBy: "\n").first ?? "?"
            let major = Int(line.components(separatedBy: " ").last?.components(separatedBy: ".").first ?? "") ?? 0
            report(major >= 16, "controller Xcode", "\(line) (need 16+)")
        } else {
            report(false, "controller Xcode", "xcodebuild not runnable")
        }
    }

    private mutating func checkArtifact() async {
        guard FileManager.default.isReadableFile(atPath: config.xctestrunPath) else {
            report(false, "xctestrun", "not readable: \(config.xctestrunPath)")
            return
        }
        do {
            let xctestrun = try XCTestRunFactory.create(path: config.xctestrunPath, log: nil)
            let platform = try xctestrun.platform()
            let selected = try xctestrun.selectedConfigurationNames(
                only: config.onlyTestConfiguration, skip: config.skipTestConfiguration
            )
            report(true, "xctestrun", "\(platform.displayName), \(selected.count) configuration(s) selected")
            // Every bundle the artifact references must actually be on disk — a
            // missing executable fails at chunk time otherwise.
            for configuration in selected {
                for descriptor in xctestrun.testBundles(config: configuration) {
                    let present = FileManager.default.isReadableFile(atPath: descriptor.executablePath)
                    report(present, "bundle \(descriptor.bundleName)",
                           present ? "executable present" : "executable missing: \(descriptor.executablePath)")
                }
            }
            if platform == .simulator {
                let discovery = TestDiscovery(log: nil)
                if (try? await discovery.enumerationDestination(for: .simulator)) != nil {
                    report(true, "enumeration destination", "a local iOS simulator is available")
                } else {
                    report(false, "enumeration destination", "no local iOS simulator for test enumeration")
                }
            }
        } catch {
            report(false, "xctestrun", "\(error)")
        }
        for (label, path) in [("setUpScript", config.setUpScriptPath), ("tearDownScript", config.tearDownScriptPath)] {
            guard let path else { continue }
            let readable = FileManager.default.isReadableFile(atPath: path)
            report(readable, label, readable ? path : "not readable: \(path)")
        }
    }

    private mutating func checkOutputDirectory() {
        let workspace = RunWorkspace(outputDirectoryPath: config.outputDirectoryPath)
        do {
            try FileManager.default.createDirectory(atPath: config.outputDirectoryPath, withIntermediateDirectories: true)
            let lock = try workspace.acquireLock()
            lock.release()
            report(true, "output directory", "\(config.outputDirectoryPath) writable, lock available")
        } catch {
            report(false, "output directory", "\(error)")
        }
    }

    // MARK: - Nodes

    private mutating func check(node: Config.NodeConfig) async {
        let label = "node '\(node.name)'"
        let executor = dependencies.sshFactory(node)
        do {
            try await executor.connect(
                username: node.usernameValue, password: node.password,
                privateKey: node.privateKey, publicKey: node.publicKey, passphrase: node.passphrase
            )
            report(true, label, node.transport == .local ? "local transport" : "SSH connection + authentication OK")
        } catch {
            report(false, label, "connection failed: \(error)")
            return
        }

        // Deployment path writable + required tools + disk space.
        let probeDirectory = "\(node.deploymentPath)/.sift/doctor-\(UUID().uuidString)"
        if let mkdir = try? await executor.run("umask 077; mkdir -p \(probeDirectory.shellQuoted) && rmdir \(probeDirectory.shellQuoted)"), mkdir.status == 0 {
            report(true, "\(label) deploymentPath", "\(node.deploymentPath) writable")
        } else {
            report(false, "\(label) deploymentPath", "cannot create \(probeDirectory)")
        }
        if let tools = try? await executor.run("command -v zip unzip xcrun >/dev/null && echo ok"), tools.output.contains("ok") {
            report(true, "\(label) tools", "zip/unzip/xcrun present")
        } else {
            report(false, "\(label) tools", "zip, unzip, or xcrun missing from PATH")
        }
        // EVERY probe reports: a probe that cannot run or parse is a FAILED check,
        // never a silently missing line.
        if let df = try? await executor.run("df -g \(node.deploymentPath.shellQuoted) | tail -1 | awk '{print $4}'"),
           let freeGB = Int(df.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            report(freeGB >= 5, "\(label) disk", "\(freeGB) GB free (need >= 5)")
        } else {
            report(false, "\(label) disk", "disk-space probe failed (df/awk unavailable or unparsable)")
        }
        if let xcode = try? await executor.run("test -d \(node.xcodePathSafeForDoctor) && echo ok"), xcode.output.contains("ok") {
            report(true, "\(label) Xcode", node.developerDirPath)
        } else {
            report(false, "\(label) Xcode", "not found at \(node.developerDirPath)")
        }
        let developerDir = "export DEVELOPER_DIR=\(node.developerDirPath.shellQuoted); "
        if let version = try? await executor.run(developerDir + "xcrun xcodebuild -version | head -1"), version.status == 0 {
            let line = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let major = Int(line.components(separatedBy: " ").last?.components(separatedBy: ".").first ?? "") ?? 0
            report(major >= 16, "\(label) Xcode version", "\(line) (need 16+)")
        } else {
            report(false, "\(label) Xcode version", "xcodebuild not runnable via \(node.developerDirPath)")
        }
        // Clock information: a large skew corrupts timestamps in logs and reports.
        if let date = try? await executor.run("date +%s"), let nodeEpoch = Int(date.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let skew = abs(Int(Date().timeIntervalSince1970) - nodeEpoch)
            report(skew <= 60, "\(label) clock", "skew vs controller: \(skew)s\(skew > 60 ? " (sync the node's clock)" : "")")
        } else {
            report(false, "\(label) clock", "clock probe failed")
        }
        if let provision = node.provisionSimulators {
            if let types = try? await executor.run(developerDir + "xcrun simctl list devicetypes"), types.status == 0,
               types.output.contains(provision.deviceType) {
                report(true, "\(label) provisioning", "device type '\(provision.deviceType)' available (\(provision.count) clone(s) requested)")
            } else {
                report(false, "\(label) provisioning", "device type '\(provision.deviceType)' not offered by simctl on this node")
            }
        }

        // Executors.
        for udid in node.UDID.simulators ?? [] {
            let simulator = Simulator(UDID: udid, config: node, sshFactory: { _ in executor }, log: nil)
            let ready = await simulator.ready()
            report(ready, "\(label) simulator \(udid)", ready ? "available" : "not found / unavailable / boot failed")
            await simulator.finish()
        }
        for udid in node.UDID.devices ?? [] {
            let device = Device(type: .device, UDID: udid, config: node, sshFactory: { _ in executor }, log: nil)
            let ready = await device.ready()
            report(ready, "\(label) device \(udid)", ready ? "visible and available" : "not visible or unavailable")
        }
        for udid in node.UDID.mac ?? [] {
            let mac = Device(type: .macOS, UDID: udid, config: node, sshFactory: { _ in executor }, log: nil)
            let ready = await mac.ready()
            report(ready, "\(label) mac \(udid)", ready ? "reachable" : "preflight failed")
        }
    }
}

private extension Config.NodeConfig {
    var xcodePathSafeForDoctor: String { developerDirPath.shellQuoted }
}
