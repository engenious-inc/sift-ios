import Foundation

class BaseExecutor {

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

    init(type: TestExecutorType,
         UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?,
         runnerDeploymentPath: String,
         masterDeploymentPath: String,
         nodeName: String,
         log: Logging?) async throws {

        self.log = log
        self.log?.prefix = config.name
        self.type = type
        self.UDID = UDID
        self.config = config
        self.xctestrunPath = xctestrunPath
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        log?.message(verboseMsg: "Open connection to: \"\(UDID)\"")
        self.ssh = try SSH(host: config.host, port: config.port, arch: config.arch)
        try self.ssh.authenticate(username: self.config.authorization.data.username,
                                  password: self.config.authorization.data.password,
                                  privateKey: self.config.authorization.data.privateKey,
                                  publicKey: self.config.authorization.data.publicKey, // not implemented on backend
                                  passphrase: self.config.authorization.data.passphrase)
        log?.message(verboseMsg: "\"\(UDID)\" connection established")
        self.xcodebuild = Xcodebuild(xcodePath: self.config.xcodePathSafe, shell: self.ssh)
        self.runnerDeploymentPath = runnerDeploymentPath
        self.masterDeploymentPath = masterDeploymentPath
        self.nodeName = nodeName
        executionFailureCounter = .init(value: 0)
    }
}
