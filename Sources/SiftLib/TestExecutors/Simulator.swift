import Foundation

struct Simulator: TestExecutor {

	var ssh: SSHExecutor
	let config: Config.NodeConfig
	let xctestrunPath: String
	let setUpScriptPath: String?
	let tearDownScriptPath: String?
	var xcodebuild: Xcodebuild!
	let type: TestExecutorType
	let UDID: String
	let runnerDeploymentPath: String
	let masterDeploymentPath: String
	let nodeName: String
	var log: Logging?
	var executionFailureCounter: Atomic<Int>
	let testsExecutionTimeout: Int
	let onlyTestConfiguration: String?
	let skipTestConfiguration: String?
	
    init(
        type: TestExecutorType,
        UDID: String,
        config: Config.NodeConfig,
        xctestrunPath: String,
        setUpScriptPath: String?,
        tearDownScriptPath: String?,
        runnerDeploymentPath: String,
        masterDeploymentPath: String,
        nodeName: String,
        testsExecutionTimeout: Int?,
        onlyTestConfiguration: String?,
        skipTestConfiguration: String?,
        log: Logging?
    ) throws {

		self.log = log
		self.log?.prefix = config.name
		self.type = type
		self.UDID = UDID
		self.config = config
		self.xctestrunPath = xctestrunPath
		self.setUpScriptPath = setUpScriptPath
		self.tearDownScriptPath = tearDownScriptPath
		self.testsExecutionTimeout = testsExecutionTimeout ?? 300
		self.onlyTestConfiguration = onlyTestConfiguration
		self.skipTestConfiguration = skipTestConfiguration
		log?.message(verboseMsg: "Open connection to: \"\(UDID)\"")
		self.ssh = try SSH(host: config.host, port: config.port, arch: config.arch)
        try self.ssh.authenticate(
            username: self.config.username,
            password: self.config.password,
            privateKey: self.config.privateKey,
            publicKey: self.config.publicKey,
            passphrase: self.config.passphrase
        )
		log?.message(verboseMsg: "\"\(UDID)\" connection established")
        self.xcodebuild = Xcodebuild(
            xcodePath: self.config.xcodePathSafe,
            shell: self.ssh,
            testsExecutionTimeout: self.testsExecutionTimeout,
            onlyTestConfiguration: onlyTestConfiguration,
            skipTestConfiguration: skipTestConfiguration
        )
		self.runnerDeploymentPath = runnerDeploymentPath
		self.masterDeploymentPath = masterDeploymentPath
		self.nodeName = nodeName
		executionFailureCounter = .init(value: 0)
	}

    func ready() async -> Bool {
        self.log?.message(verboseMsg: "check Simulator \"\(self.UDID)\"")
        let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n"
        var command = [
            prefixCommand,
            "xcrun simctl list devices",
            " | grep \"(Booted)\"",
            " | grep -E -o -i \"([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})\""
        ]

        guard let output = try? await self.ssh.run(command.joined()).output else {
            self.log?.message(verboseMsg: "Error: can't run \"\(command.joined())\"")
            return false
        }
        
        if output.contains(UDID + "\n") {
            return true
        }
                
        command[2] = ""
        guard let output = try? await self.ssh.run(command.joined()).output else {
            self.log?.message(verboseMsg: "Error: can't run \"\(command.joined())\"")
            return false
        }
        
        if output.contains(UDID + "\n") {
            self.log?.message("Simulator \"\(UDID)\" is not booted.")
            await reset()
            return true
        }
        
        log?.warning("Simulator: \(UDID) not found and will be ignored in test run")
        
        return false
    }
    
    @discardableResult
    func reset() async -> Result<TestExecutor, Error> {
        self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") reseting...")
        let commands = "/bin/sh -c '" +
        "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n" +
        "xcrun simctl shutdown \(self.UDID)\n" +
        "xcrun simctl erase \(self.UDID)\n" +
        "xcrun simctl boot \(self.UDID)'\n" +
        "sleep 5"
        
        do {
            try await self.ssh.run(commands)
            self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") reseted")
            return .success(self)
        } catch let err {
            return .failure(NSError(domain: "Simulator: \(self.UDID) - \(err)", code: 1, userInfo: nil))
        }
    }
    
    func deleteApp(bundleId: String) async {
        _ = try? await self.ssh.run("xcrun simctl uninstall \(self.UDID) \(bundleId)")
    }
}
