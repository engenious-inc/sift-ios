import Foundation

class Device: BaseExecutor {

	override init(type: TestExecutorType,
				  UDID: String,
				  config: Config.NodeConfig,
				  xctestrunPath: String,
				  setUpScriptPath: String?,
				  tearDownScriptPath: String?,
                  log: Logging?) throws {

		try super.init(type: type,
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

    func ready(completion: @escaping (Bool) -> Void) {
        self.queue.async(flags: .barrier) {
            self.log?.message(verboseMsg: "Device: \"\(self.UDID)\" ready")
            completion(true)
        }
    }
    
    func run(tests: [String],
             completion: ((TestExecutor, Result<[String], TestExecutorError>) -> Void)? = nil) {
        self.queue.async(flags: .barrier) {
            if tests.isEmpty {
                completion?(self, .failure(.noTestsForExecution))
                return
            }
            do {
                if try self.executeShellScript(path: self.setUpScriptPath, testNameEnv: tests.first ?? "") == 1 {
                    completion?(self, .failure(.testSkipped))
                    return
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
                    completion?(self, .success(tests))
                    return
                }
                self.log?.message(verboseMsg: "\"\(self.UDID)\" " +
                "xcodebuild:\n \(result.output)")
                self.reset { _ in
                    completion?(self, .failure(.executionError(description: "Device: \(self.UDID) " +
                        "- status \(result.status) " +
                        "\(result.status == 143 ? "- timeout" : "")",
                        tests: tests)))
                }
            } catch let err {
                self.reset { _ in
                    completion?(self, .failure(.executionError(description: "Device: \(self.UDID) - \(err)", tests: tests)))
                }
            }
        }
    }
    
    func reset(completion: ((Result<TestExecutor, Error>) -> Void)? = nil) {
        completion?(.success(self))
    }

    func deleteApp(bundleId: String) {}
}
