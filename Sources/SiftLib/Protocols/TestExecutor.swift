import Foundation

public protocol TestExecutor: Sendable {
    var type: TestExecutorType { get }
    var UDID: String { get }
    var log: Logging? { get }
    var setUpScriptPath: String? { get }
    var tearDownScriptPath: String? { get }
    var config: Config.NodeConfig { get }
    var ssh: SSHExecutor { get }
    var xctestrunPath: String { get }
    var runnerDeploymentPath: String { get }
    var masterDeploymentPath: String { get }
    var nodeName: String { get }
    var executionFailureCounter: Atomic<Int> { get }
	var testsExecutionTimeout: Int { get }
	var onlyTestConfiguration: String? { get }
	var skipTestConfiguration: String? { get }
    func ready() -> Bool
    func run(tests: [String]) async -> (TestExecutor, Result<[String], TestExecutorError>)
    @discardableResult
    func reset() -> Result<TestExecutor, Error>
    func deleteApp(bundleId: String) async
}

extension TestExecutor {
    func run(tests: [String]) async -> (TestExecutor, Result<[String], TestExecutorError>) {
        if tests.isEmpty {
            return (self, .failure(.noTestsForExecution))
        }
        do {
			let xcodebuild = Xcodebuild(xcodePath: self.config.xcodePathSafe, shell: self.ssh, testsExecutionTimeout: self.testsExecutionTimeout, onlyTestConfiguration: onlyTestConfiguration, skipTestConfiguration: skipTestConfiguration)
            if try self.executeShellScript(path: self.setUpScriptPath, testNameEnv: tests.first ?? "") == 1 {
                return (self, .failure(.testSkipped))
            }

            self.log?.message(verboseMsg: "\(type): \"\(self.UDID)\") run tests:\n\t\t- " +
                                    "\(tests.joined(separator: "\n\t\t- "))")
            let result = try await xcodebuild.execute(tests: tests,
                                                 executorType: self.type,
                                                 UDID: self.UDID,
                                                 xctestrunPath: self.xctestrunPath,
                                                 derivedDataPath: self.config.deploymentPath,
                                                 log: self.log)
            self.log?.message(verboseMsg: "\(type): \"\(self.UDID)\") " +
                                    "tests run finished with status: \(result)")

            try self.executeShellScript(path: self.tearDownScriptPath, testNameEnv: tests.first ?? "")
            if result == 0 || result == 65 {
                return (self, .success(tests))
            }
            
			self.reset()
            return (self, .failure(.executionError(description: "\(type): \(self.UDID) " +
            "- status \(result) " +
            "\(result == 143 ? "- timeout" : "")",
            tests: tests)))
        } catch let err {
            await executionFailureCounter.increment()
			self.reset()
            return (self, .failure(.executionError(description: "\(type): \(self.UDID) - \(err)", tests: tests)))
        }
    }
    
    @discardableResult
    func executeShellScript(path: String?, testNameEnv: String) throws -> Int32? {
        if let scriptPath = path {
            log?.message(verboseMsg: "\"\(self.UDID)\" executing \"\(scriptPath)\" script...")
            let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
            let env = "export TEST_NAME='\(testNameEnv)'\n" +
                      "export UDID='\(UDID)'\n" +
                (self.config
                    .environmentVariables?
                    .map { "export \($0.key)=\($0.value)" }
                    .joined(separator: "\n") ?? "")
            let scriptExecutionResult = try self.ssh.run(env + script)
            log?.message(verboseMsg: "Device: \"\(self.UDID)\"\n\(scriptExecutionResult.output)")
            return scriptExecutionResult.status
        }
        return nil
    }
    
    func sendResultsToMaster() throws -> String? {
        log?.message(verboseMsg: "\(self.nodeName): Uploading tests result to master...")
        let resultsFolderPath = "\(self.runnerDeploymentPath)/\(UDID)/Logs/Test"
        let (_, filesString) = try self.ssh.run("ls -1 \(resultsFolderPath) | grep -E '.\\.xcresult$'")
        let xcresultFiles =  filesString.components(separatedBy: "\n")
        guard let xcresult = (xcresultFiles.filter { $0.contains(".xcresult") }.sorted { $0 > $1 }).first else {
            log?.error("*.xcresult files not found in \(resultsFolderPath): \n \(filesString)")
            return nil
        }
        log?.message(verboseMsg: "\(self.nodeName): Test results: \(xcresult)")
		let masterPath = "\(self.masterDeploymentPath)/\(UUID().uuidString).zip"
        try self.ssh.run("cd '\(resultsFolderPath)'\n" + "zip -r -X -q -0 './\(UDID).zip' './\(xcresult)'")
        try self.ssh.downloadFile(remotePath: "\(resultsFolderPath)/\(UDID).zip", localPath: "\(masterPath)")
        _ = try? self.ssh.run("rm -r \(resultsFolderPath)")
        log?.message(verboseMsg: "\(self.nodeName): Successfully uploaded on master: \(masterPath)")
        return masterPath
    }
}

public enum TestExecutorType: String, Sendable {
    case simulator = "iOS Simulator"
    case device = "iOS"
	case macOS = "macOS"
}

public enum TestExecutorError: Error {
    case noTestsForExecution
    case executionError(description: String, tests: [String])
    case testSkipped
}
