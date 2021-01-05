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
    let UDID: String
    private var _finished: Bool = false
    var finished: Bool {
        get {
            self.queue.sync(flags: .barrier) { self._finished }
        }
        set {
            self.queue.async(flags: .barrier) { self._finished = newValue }
        }
    }

    init(UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?) throws {

        self.UDID = UDID
        self.config = config
        self.xctestrunPath = xctestrunPath
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.threadName = UDID
        self.queue = .init(type: .serial, name: self.threadName)
        try self.queue.sync {
            Log.message(verboseMsg: "\(config.name) Open connection to: \"\(UDID)\"")
            self.ssh = try SSH(host: config.host, port: config.port)
            try self.ssh.authenticate(username: self.config.username,
                                      password: self.config.password,
                                      privateKey: self.config.privateKey,
                                      publicKey: self.config.publicKey,
                                      passphrase: self.config.passphrase)
            Log.message(verboseMsg: "\(config.name) \"\(UDID)\" connection established")
            self.xcodebuild = Xcodebuild(xcodePath: self.config.xcodePath, shell: self.ssh)
        }
    }
    
    @discardableResult
    func executeShellScript(path: String?, testNameEnv: String) throws -> Int32? {
        if let scriptPath = path {
            Log.message(verboseMsg: "\(self.config.name) \"\(self.UDID)\" executing \"\(scriptPath)\" script...")
            let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
            let env = "export TEST_NAME='\(testNameEnv)'\n" +
                      "export UDID='\(UDID)'\n" +
                (self.config
                    .environmentVariables?
                    .compactMap { $0.value != nil ? "export \($0.key)=\($0.value!)" : nil }
                    .joined(separator: "\n") ?? "")
            let scriptExecutionResult = try self.ssh.run(env + script)
            Log.message(verboseMsg: "\(self.config.name) Device: \"\(self.UDID)\"\n\(scriptExecutionResult.output)")
            return scriptExecutionResult.status
        }
        return nil
    }
}
