import Foundation

class Device: BaseExecutor {

    let type: TestExecutorType

    override init(UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?) throws {

        self.type = .device
        try super.init(UDID: UDID,
                   config: config,
                   xctestrunPath: xctestrunPath,
                   setUpScriptPath: setUpScriptPath,
                   tearDownScriptPath: tearDownScriptPath)
    }
}

// MARK: - TestExecutor Protocol implementation

extension Device: TestExecutor {

    func ready(completion: @escaping (Bool) -> Void) {
        self.serialQueue.async {
            guard let output = try? self.ssh.run("instruments -s devices").output,
                  output.contains(self.UDID) else {
                error("Device: \(self.UDID) is not connected.")
                completion(false)
                return
            }
            completion(true)
        }
    }
    
    func run(tests: [String],
             timeout: Int,
             completion: ((TestExecutor, Result<[String], TestExecutorError>) -> Void)? = nil) {
        self.serialQueue.async {
            if tests.isEmpty {
                self._finished = true
                completion?(self, .failure(.noTestsForExecution))
                return
            }
            do {
                if try self.executeShellScript(path: self.setUpScriptPath, testNameEnv: tests.first ?? "") == 1 {
                    completion?(self, .failure(.testSkipped))
                    return
                }
                
                let result = try self.xcodebuild.execute(tests: tests,
                                                         executorType: self.type,
                                                         UDID: self.UDID,
                                                         xctestrunPath: self.xctestrunPath,
                                                         derivedDataPath: self.derivedDataPath,
                                                         timeout: timeout)
                
                try self.executeShellScript(path: self.tearDownScriptPath, testNameEnv: tests.first ?? "")
                
                if result.status == 0 || result.status == 65 {
                    completion?(self, .success(tests))
                    return
                }
                // timeout
                if result.status == 143 {
                    self.reset()
                    sleep(3)
                }
                completion?(self, .failure(.executionError(description: "Device: \(self.UDID) " +
                    "- status \(result.status) " +
                    "\(result.status == 143 ? "- timeout: \(timeout)" : "")",
                    tests: tests)))
            } catch let err {
                completion?(self, .failure(.executionError(description: "Device: \(self.UDID) - \(err)", tests: tests)))
            }
        }
    }
    
    func reset(completion: ((TestExecutor, Error?) -> Void)? = nil) {}
    func deleteApp(bundleId: String) {}
}
