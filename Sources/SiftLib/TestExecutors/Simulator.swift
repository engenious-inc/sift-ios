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
        self.queue.async(flags: .barrier) {
            Log.message(verboseMsg: "\(self.config.name): check Simulator \"\(self.UDID)\"")
            let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePath)/Contents/Developer\n"
            guard let output = try? self.ssh.run(prefixCommand +
                "xcrun simctl list devices" +
                " | grep \"(Booted)\" | grep -E -o -i \"([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})\"").output else {
                Log.message(verboseMsg: "\(self.config.name): Simulator \"\(self.UDID)\" is not booted.")
                completion(false)
                return
            }
            let udids = output.components(separatedBy: "\n")
            let result = udids.contains { self.UDID == $0 }
            if !result {
                Log.message(verboseMsg: "\(self.config.name): Simulator \"\(self.UDID)\" is not booted.")
            }
            completion(result)
        }
    }
    
    func run(tests: [String],
             timeout: Int,
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
                Log.message(verboseMsg: "\(self.config.name) Semulator: \"\(self.UDID)\") run tests:\n\t\t- " +
                                        "\(tests.joined(separator: "\n\t\t- "))")
                let result = try self.xcodebuild.execute(tests: tests,
                                                         executorType: self.type,
                                                         UDID: self.UDID,
                                                         xctestrunPath: self.xctestrunPath,
                                                         derivedDataPath: self.config.deploymentPath,
                                                         timeout: timeout)
                Log.message(verboseMsg: "\(self.config.name) Simulator: \"\(self.UDID)\") " +
                                        "tests run finished with status: \(result.status)")
                try self.executeShellScript(path: self.tearDownScriptPath, testNameEnv: tests.first ?? "")
                if result.status == 0 || result.status == 65 {
                    completion?(self, .success(tests))
                    return
                }
                Log.message(verboseMsg: "\(self.config.name) \"\(self.UDID)\" " +
                "xcodebuild:\n \(result.output)")
                self.reset { _ in
                    completion?(self, .failure(.executionError(description: "Simulator: \(self.UDID) " +
                    "- status \(result.status) " +
                    "\(result.status == 143 ? "- timeout: \(timeout)" : "")",
                    tests: tests)))
                }
            } catch let err {
                self.reset { _ in
                    completion?(self, .failure(.executionError(description: "Simulator: \(self.UDID) - \(err)", tests: tests)))
                }
            }
        }
    }
    
    func reset(completion: ((Result<TestExecutor, Error>) -> Void)? = nil) {
        self.queue.async(flags: .barrier) {
            Log.message(verboseMsg: "\(self.config.name) Simulator: \"\(self.UDID)\") reseting...")
            var commands = "/bin/sh -c '" +
                "export DEVELOPER_DIR=\(self.config.xcodePath)/Contents/Developer\n" +
                           "xcrun simctl shutdown \(self.UDID)\n" +
                           "xcrun simctl erase \(self.UDID)\n" +
                           "xcrun simctl erase \(self.UDID)\n" + // doubled due to simulator bug
                           "xcrun simctl boot \(self.UDID)'"
            
            // in case when completion is not set, run all commands in background
            if completion == nil {
                commands = "nohup \(commands) &"
            }
            
            do {
                try self.ssh.run(commands)
                Log.message(verboseMsg: "\(self.config.name) Simulator: \"\(self.UDID)\") reseted")
                completion?(.success(self))
            } catch let err {
                completion?(.failure(NSError(domain: "Simulator: \(self.UDID) - \(err)", code: 1, userInfo: nil)))
            }
        }
    }
    
    func deleteApp(bundleId: String) {
        self.queue.async(flags: .barrier) {
            _ = try? self.ssh.run("xcrun simctl uninstall \(self.UDID) \(bundleId)")
        }
    }
}
