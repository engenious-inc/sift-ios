import Foundation

class BaseExecutor {

    var ssh: SSHExecutor!
    let threadName: String
    let serialQueue: Queue
    let xcodePath: String
    let xctestrunPath: String
    let setUpScriptPath: String?
    let tearDownScriptPath: String?
    let derivedDataPath: String
    var xcodebuild: Xcodebuild!
    let _UDID: String
    var _finished: Bool = false
    
    var UDID: String { self.serialQueue.sync { self._UDID } }
    var finished: Bool { self.serialQueue.sync { self._finished } }
    
    init(UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?) throws {

        self._UDID = UDID
        self.xcodePath = config.xcodePath
        self.xctestrunPath = xctestrunPath
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.derivedDataPath = config.deploymentPath
        self.threadName = UDID
        self.serialQueue = .init(type: .serial, name: self.threadName)
        try self.serialQueue.sync {
            self.ssh = try SSH(host: config.host, port: config.port)
            try self.ssh.authenticate(username: config.username, password: config.password)
            self.xcodebuild = Xcodebuild(xcodePath: self.xcodePath, shell: self.ssh)
        }
    }
    
    @discardableResult
    func executeShellScript(path: String?, testNameEnv: String) throws -> Int32? {
        if let scriptPath = path {
            let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
            let env = "export TEST_NAME='\(testNameEnv)'\n"
            let scriptExecutionResult = try self.ssh.run(env + script)
            return scriptExecutionResult.status
        }
        return nil
    }
}
