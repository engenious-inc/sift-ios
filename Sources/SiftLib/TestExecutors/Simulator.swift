import Foundation

class Simulator: BaseExecutor {

    override init(type: TestExecutorType,
                  UDID: String,
                  config: Config.NodeConfig,
                  xctestrunPath: String,
                  setUpScriptPath: String?,
                  tearDownScriptPath: String?,
                  runnerDeploymentPath: String,
                  masterDeploymentPath: String,
                  nodeName: String,
                  log: Logging?) async throws {

        try await super.init(type: type,
                       UDID: UDID,
                       config: config,
                       xctestrunPath: xctestrunPath,
                       setUpScriptPath: setUpScriptPath,
                       tearDownScriptPath: tearDownScriptPath,
                       runnerDeploymentPath: runnerDeploymentPath,
                       masterDeploymentPath: masterDeploymentPath,
                       nodeName: nodeName,
                       log: log)
    }
}

// MARK: - TestExecutor Protocol implementation

extension Simulator: TestExecutor {

    func ready() async -> Bool {
        self.log?.message(verboseMsg: "check Simulator \"\(self.UDID)\"")
        let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n"
        var command = [prefixCommand,
                       "xcrun simctl list devices",
                       " | grep \"(Booted)\"",
                       " | grep -E -o -i \"([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})\""]
        
        guard let output = try? self.ssh.run(command.joined()).output else {
            self.log?.message(verboseMsg: "Error: can't run \"\(command.joined())\"")
            return false
        }
        
        if output.contains(UDID + "\n") {
            return true
        }
                
        command[2] = ""
        guard let output = try? self.ssh.run(command.joined()).output else {
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
        let commands = ""
//        let commands = "/bin/sh -c '" +
//            "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n" +
//                       "xcrun simctl shutdown \(self.UDID)\n" +
//                       "sleep 5\n" +
//                       "xcrun simctl erase \(self.UDID)\n" +
//                       "sleep 5\n" +
//                       "xcrun simctl boot \(self.UDID)'\n" +
//                       "sleep 5"
        
        do {
            try self.ssh.run(commands)
            self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") reseted")
            return .success(self)
        } catch let err {
            return .failure(NSError(domain: "Simulator: \(self.UDID) - \(err)", code: 1, userInfo: nil))
        }
    }
    
    func deleteApp(bundleId: String) {
        _ = try? self.ssh.run("xcrun simctl uninstall \(self.UDID) \(bundleId)")
    }
}
