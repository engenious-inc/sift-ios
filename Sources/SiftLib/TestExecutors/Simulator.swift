import Foundation

class Simulator: BaseExecutor {

    let type: TestExecutorType

    override init(UDID: String,
         config: Config.NodeConfig,
         xctestrunPath: String,
         setUpScriptPath: String?,
         tearDownScriptPath: String?) throws {

        self.type = .simulator
        try super.init(UDID: UDID,
                   config: config,
                   xctestrunPath: xctestrunPath,
                   setUpScriptPath: setUpScriptPath,
                   tearDownScriptPath: tearDownScriptPath)
    }
}

// MARK: - TestExecutor Protocol implementation

extension Simulator: TestExecutor {

    func ready(completion: @escaping (Bool) -> Void) {
        self.serialQueue.async {
            guard let output = try? self.ssh.run("xcrun simctl list devices" +
                " | grep \"(Booted)\" | grep -E -o -i \"([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})\"").output else {
                completion(false)
                return
            }
            let udids = output.components(separatedBy: "\n")
            completion(udids.contains { self.UDID == $0 })
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
                completion?(self, .failure(.executionError(description: "Simulator: \(self.UDID) " +
                    "- status \(result.status) " +
                    "\(result.status == 143 ? "- timeout: \(timeout)" : "")",
                    tests: tests)))
            } catch let err {
                completion?(self, .failure(.executionError(description: "Simulator: \(self.UDID) - \(err)", tests: tests)))
            }
        }
    }
    
    func reset(completion: ((TestExecutor, Error?) -> Void)? = nil) {
        self.serialQueue.async {
            do {
                _ = try self.ssh.run("nohup /bin/sh -c '" +
                    "export DEVELOPER_DIR=\(self.xcodePath)/Contents/Developer\n" +
                    "xcrun simctl shutdown \(self.UDID)\n" +
                    "xcrun simctl erase \(self.UDID)\n" +
                    "xcrun simctl boot \(self.UDID)' &").output
                completion?(self, nil)
            } catch let err {
                completion?(self, NSError(domain: "Simulator: \(self.UDID) - \(err)", code: 1, userInfo: nil))
            }
        }
    }
    
    func deleteApp(bundleId: String) {
        self.serialQueue.async {
            _ = try? self.ssh.run("xcrun simctl uninstall \(self.UDID) \(bundleId)").output
        }
    }
}
