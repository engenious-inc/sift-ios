import Foundation

class BaseExecutor {

    var ssh: SSHExecutor!
    let threadName: String
    let queue: Queue
    let config: Config.NodeConfig
    let xctestrunPath: String
    let setUpScriptPath: String?
    let tearDownScriptPath: String?
    var xcodebuild: Xcodebuild!
	let type: TestExecutorType
    let UDID: String
    var log: Logging?
    private var _finished: Bool = false
    var finished: Bool {
        get {
            self.queue.sync(flags: .barrier) { self._finished }
        }
        set {
            self.queue.async(flags: .barrier) { self._finished = newValue }
        }
    }

    init(type: TestExecutorType,
		 UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?,
         log: Logging?) throws {

        self.log = log
        self.log?.prefix = config.name
		self.type = type
        self.UDID = UDID
        self.config = config
        self.xctestrunPath = xctestrunPath
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.threadName = UDID
        self.queue = .init(type: .serial, name: self.threadName)
        try self.queue.sync {
            log?.message(verboseMsg: "Open connection to: \"\(UDID)\"")
			self.ssh = try SSH(host: config.host, port: config.port, arch: config.arch)
            try self.ssh.authenticate(username: self.config.username,
                                      password: self.config.password,
                                      privateKey: self.config.privateKey,
                                      publicKey: self.config.publicKey,
                                      passphrase: self.config.passphrase)
            log?.message(verboseMsg: "\"\(UDID)\" connection established")
            self.xcodebuild = Xcodebuild(xcodePath: self.config.xcodePathSafe, shell: self.ssh)
        }
    }
    
    @discardableResult
    func executeShellScript(path: String?, testNameEnv: String) throws -> Int32? {
        if let scriptPath = path {
            log?.message(verboseMsg: "\"\(self.UDID)\" executing \"\(scriptPath)\" script...")
            let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
            let env = "export TEST_NAME='\(testNameEnv)'\n" +
                      "export UDID='\(UDID)'\n" +
                (self.config
                    .environmentVariables?
					.map { "export \($0.key)=\($0.value)" }
                    .joined(separator: "\n") ?? "")
            let scriptExecutionResult = try self.ssh.run(env + script)
            log?.message(verboseMsg: "Device: \"\(self.UDID)\"\n\(scriptExecutionResult.output)")
            return scriptExecutionResult.status
        }
        return nil
    }
}
