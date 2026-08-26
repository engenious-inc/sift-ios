import Foundation

struct Device: TestExecutor {

	var ssh: SSHExecutor
	let config: Config.NodeConfig
	let xctestrunPath: String
	let setUpScriptPath: String?
	let tearDownScriptPath: String?
	let xcodebuild: Xcodebuild
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

    func ready() -> Bool{
        self.log?.message(verboseMsg: "Device: \"\(self.UDID)\" ready")
        return true
    }
    
    @discardableResult
    func reset() -> Result<TestExecutor, Error> {
        return .success(self)
    }

    func deleteApp(bundleId: String) {}
}
