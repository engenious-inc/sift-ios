import Foundation

class Device: BaseExecutor {

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

extension Device: TestExecutor {

    func ready() async -> Bool{
        self.log?.message(verboseMsg: "Device: \"\(self.UDID)\" ready")
        return true
    }
    
    func run(tests: [String]) async -> (TestExecutor, Result<[String], TestExecutorError>) {
        if tests.isEmpty {
            return (self, .failure(.noTestsForExecution))
        }
        do {
            if try self.executeShellScript(path: self.setUpScriptPath, testNameEnv: tests.first ?? "") == 1 {
                return (self, .failure(.testSkipped))
            }
            self.log?.message(verboseMsg: "\"\(self.UDID)\" run tests:\n\t\t- " +
                                    "\(tests.joined(separator: "\n\t\t- "))")
            let result = try self.xcodebuild.execute(tests: tests,
                                                     executorType: self.type,
                                                     UDID: self.UDID,
                                                     xctestrunPath: self.xctestrunPath,
                                                     derivedDataPath: self.config.deploymentPath,
                                                     log: self.log)
            self.log?.message(verboseMsg: "\"\(self.UDID)\" " +
                                    "tests run finished with status: \(result.status)")
            if result.status != 0 {
                self.log?.message(verboseMsg: result.output)
            }
            try self.executeShellScript(path: self.tearDownScriptPath, testNameEnv: tests.first ?? "")
            if result.status == 0 || result.status == 65 {
                return (self, .success(tests))
            }
            self.log?.message(verboseMsg: "\"\(self.UDID)\" " +
            "xcodebuild:\n \(result.output)")
            await self.reset()
            return (self, .failure(.executionError(description: "Device: \(self.UDID) " +
                "- status \(result.status) " +
                "\(result.status == 143 ? "- timeout" : "")",
                tests: tests)))
        } catch let err {
            await self.reset()
            return (self, .failure(.executionError(description: "Device: \(self.UDID) - \(err)", tests: tests)))
        }
    }
    
    @discardableResult
    func reset() async -> Result<TestExecutor, Error> {
        return .success(self)
    }

    func deleteApp(bundleId: String) {}
}
