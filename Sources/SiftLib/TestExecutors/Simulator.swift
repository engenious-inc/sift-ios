import Foundation

class Simulator: BaseExecutor {

    override init(type: TestExecutorType,
				  UDID: String,
                  config: Config.NodeConfig,
                  xctestrunPath: String,
                  setUpScriptPath: String?,
                  tearDownScriptPath: String?,
                  log: Logging?) async throws {

		try await super.init(type: type,
					   UDID: UDID,
                       config: config,
                       xctestrunPath: xctestrunPath,
                       setUpScriptPath: setUpScriptPath,
                       tearDownScriptPath: tearDownScriptPath,
                       log: log)
    }
}

// MARK: - TestExecutor Protocol implementation

extension Simulator: TestExecutor {

    func ready() async -> Bool {
        self.log?.message(verboseMsg: "check Simulator \"\(self.UDID)\"")
        let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n"
        guard let output = try? self.ssh.run(prefixCommand +
            "xcrun simctl list devices" +
            " | grep \"(Booted)\" | grep -E -o -i \"([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})\"").output else {
            self.log?.message(verboseMsg: "Simulator \"\(self.UDID)\" is not booted.")
            return false
        }
        let udids = output.components(separatedBy: "\n")
        let result = udids.contains { self.UDID == $0 }
        if !result {
            self.log?.message(verboseMsg: "Simulator \"\(self.UDID)\" is not booted.")
        }
        return result
    }
    
    func run(tests: [String]) async -> (TestExecutor, Result<[String], TestExecutorError>) {
        if tests.isEmpty {
            return (self, .failure(.noTestsForExecution))
        }
        do {
            if try self.executeShellScript(path: self.setUpScriptPath, testNameEnv: tests.first ?? "") == 1 {
                return (self, .failure(.testSkipped))
            }
            self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") run tests:\n\t\t- " +
                                    "\(tests.joined(separator: "\n\t\t- "))")
            let result = try self.xcodebuild.execute(tests: tests,
                                                     executorType: self.type,
                                                     UDID: self.UDID,
                                                     xctestrunPath: self.xctestrunPath,
                                                     derivedDataPath: self.config.deploymentPath,
                                                     quiet: !verbose,
                                                     log: self.log)
            self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") " +
                                    "tests run finished with status: \(result.status)")
            if result.status != 0 {
                let message = "Xcode output:\n" +
                              ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n" + result.output +
                              "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"
                self.log?.message(verboseMsg: message)
            }
            try self.executeShellScript(path: self.tearDownScriptPath, testNameEnv: tests.first ?? "")
            if result.status == 0 || result.status == 65 {
                return (self, .success(tests))
            }
            self.log?.message(verboseMsg: "\"\(self.UDID)\" " +
            "xcodebuild:\n \(result.output)")
            await self.reset()
            return (self, .failure(.executionError(description: "Simulator: \(self.UDID) " +
            "- status \(result.status) " +
            "\(result.status == 143 ? "- timeout" : "")",
            tests: tests)))
        } catch let err {
            await self.reset()
            return (self, .failure(.executionError(description: "Simulator: \(self.UDID) - \(err)", tests: tests)))
        }
    }
    
    @discardableResult
    func reset() async -> Result<TestExecutor, Error> {
        self.log?.message(verboseMsg: "Simulator: \"\(self.UDID)\") reseting...")
        let commands = "/bin/sh -c '" +
            "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n" +
                       "xcrun simctl shutdown \(self.UDID)\n" +
                       "xcrun simctl erase \(self.UDID)\n" +
                       "xcrun simctl boot \(self.UDID)'"
        
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
