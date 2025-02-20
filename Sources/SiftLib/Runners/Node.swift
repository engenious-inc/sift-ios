import Foundation
import CollectionConcurrencyKit

struct Node: Sendable {
    
    private let config: Config.NodeConfig
    private let outputDirectoryPath: String
    private let testsExecutionTimeout: Int?
    private let setUpScriptPath: String?
    private let tearDownScriptPath: String?
	private var onlyTestConfiguration: String?
	private var skipTestConfiguration: String?
    private let communication: Communication
    private let log: Logging?
    
    let name: String
    let delegate: RunnerDelegate
    
    init(
        config: Config.NodeConfig,
        outputDirectoryPath: String,
        testsExecutionTimeout: Int?,
        setUpScriptPath: String?,
        tearDownScriptPath: String?,
        onlyTestConfiguration: String?,
        skipTestConfiguration: String?,
        delegate: RunnerDelegate,
        log: Logging?
    ) throws {
        self.log = log
        self.config = config
        self.outputDirectoryPath = outputDirectoryPath
        self.testsExecutionTimeout = testsExecutionTimeout
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.name = config.name
		self.onlyTestConfiguration = onlyTestConfiguration
		self.skipTestConfiguration = skipTestConfiguration
        self.delegate = delegate
        
        log?.message(verboseMsg: "\(self.name) Created")
		communication = try SSHCommunication<SSH>(
			host: config.host,
			port: config.port,
			username: config.username,
			password: config.password,
			privateKey: config.privateKey,
			publicKey: config.publicKey,
			passphrase: config.passphrase,
			runnerDeploymentPath: config.deploymentPath,
			masterDeploymentPath: outputDirectoryPath,
			nodeName: config.name,
			arch: config.arch,
			log: log
		)
    }
}

// MARK: - Runner Protocol implementation

extension Node: Runner {
    
	func start() async {
        do {
            try communication.getBuildOnRunner(buildPath: await delegate.buildPath())
            
            let xctestrun = try injectENVToXctestrun() // all env should be injected in to the .xctestrun file
            let xctestrunPath = try communication.saveOnRunner(xctestrun: xctestrun) // save *.xctestrun file on Node side
            
            let executors = createExecutors(xctestrunPath: xctestrunPath)
            guard !executors.isEmpty else {
                return
            }
            
            await executors.concurrentForEach { executor in
                if executor.ready() {
                    await self.runTests(in: executor)
                }
            }
			self.finish(executors: executors)
        } catch {
            self.log?.error("\(name): \(error)")
            return
        }
    }

    private func createExecutors(xctestrunPath: String) -> [TestExecutor] {
        if let simulators = self.config.UDID.simulators, !simulators.isEmpty {
            return simulators.compactMap {
                do {
					return try Simulator(
						type: .simulator,
						UDID: $0,
						config: self.config,
						xctestrunPath: xctestrunPath,
						setUpScriptPath: self.setUpScriptPath,
						tearDownScriptPath: self.tearDownScriptPath,
						runnerDeploymentPath: config.deploymentPath,
						masterDeploymentPath: outputDirectoryPath,
						nodeName: config.name,
						testsExecutionTimeout: testsExecutionTimeout,
						onlyTestConfiguration: onlyTestConfiguration,
						skipTestConfiguration: skipTestConfiguration,
						log: log
					)
                } catch {
                    self.log?.error("\(self.name): \(error)")
                    return nil
                }
            }
        }
        
        if let devices = self.config.UDID.devices {
            return devices.compactMap {
                do {
                    return try Device(
                        type: .device,
                        UDID: $0,
                        config: self.config,
                        xctestrunPath: xctestrunPath,
                        setUpScriptPath: self.setUpScriptPath,
                        tearDownScriptPath: self.tearDownScriptPath,
                        runnerDeploymentPath: config.deploymentPath,
                        masterDeploymentPath: outputDirectoryPath,
                        nodeName: config.name,
                        testsExecutionTimeout: testsExecutionTimeout,
                        onlyTestConfiguration: onlyTestConfiguration,
                        skipTestConfiguration: skipTestConfiguration,
                        log: log
                    )
                } catch let err {
                    self.log?.error("\(self.name): \(err)")
                    return nil
                }
            }

        }
		
		if let mac = self.config.UDID.mac {
			return mac.compactMap {
				do {
                    return try Device(
                        type: .macOS,
                        UDID: $0,
                        config: self.config,
                        xctestrunPath: xctestrunPath,
                        setUpScriptPath: self.setUpScriptPath,
                        tearDownScriptPath: self.tearDownScriptPath,
                        runnerDeploymentPath: config.deploymentPath,
                        masterDeploymentPath: outputDirectoryPath,
                        nodeName: config.name,
                        testsExecutionTimeout: testsExecutionTimeout,
                        onlyTestConfiguration: onlyTestConfiguration,
                        skipTestConfiguration: skipTestConfiguration,
                        log: log
                    )
				} catch let err {
                    self.log?.error("\(self.name): \(err)")
					return nil
				}
			}
		}
        return []
    }
    
    private func runTests(in executor: TestExecutor) async {
        let testsForExecution = await self.delegate.getTests() // request tests for execution
        if testsForExecution.isEmpty {
            return
        }
        let (executor, result) = await executor.run(tests: testsForExecution)
        /*
         .success - doesn't mean that tests is passed, just means that tests was successfully executed
         .failure - tests was not executed.
        */
        switch result {
        case .success(let tests):
            await self.testExecutionSuccessFlow(tests, executor: executor)
        case .failure(let error):
            await self.testExecutionFailureFlow(error, executor: executor)
        }
    }
    
    private func testExecutionSuccessFlow(_ tests: [String], executor: TestExecutor) async {
        do {
            let pathToTestsResults = try executor.sendResultsToMaster()
            await self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: pathToTestsResults)
            await self.runTests(in: executor) // continue running next tests
        } catch let err {
            self.log?.error("\(self.name): \(err)")
            await self.runTests(in: executor)
        }
    }
    
    private func testExecutionFailureFlow(_ error: TestExecutorError, executor: TestExecutor) async {
        switch error {
        case .noTestsForExecution:
            self.log?.message(verboseMsg: "\(self.name): No more tests for execution")
        case .executionError(let description, let tests):
            self.log?.error(description)
            await self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: nil)
            if await executor.executionFailureCounter.getValue() < 2 {
                await self.runTests(in: executor) // continue running next tests
            }
        case .testSkipped:
            self.log?.message(verboseMsg: "\(self.name): test skipped")
            await self.runTests(in: executor) // continue running next tests
        }
    }
    
    private func injectENVToXctestrun() throws -> XCTestRun {
        var xctestrun = try self.delegate.XCTestRun()
        self.log?.message(verboseMsg: "\(self.name): Injecting environment variables: \(self.config.environmentVariables ?? [:])")
        xctestrun.addEnvironmentVariables(self.config.environmentVariables)
        if let testsExecutionTimeout = testsExecutionTimeout {
            xctestrun.add(timeout: testsExecutionTimeout)
        }
        return xctestrun
    }
    
	private func finish(executors: [any TestExecutor], reset: Bool = true) {
		executors.forEach { executor in
			self.log?.message(verboseMsg: "\(self.name) \(executor.type.rawValue): \"\(executor.UDID)\") finished")
            executor.reset()
		}
        self.log?.message(verboseMsg: "\(self.name): FINISHED")
    }
    
    private func launchSimulator() {
        log?.message(verboseMsg: "Launch: \(config.xcodePathSafe)/Contents/Developer/Applications/Simulator.app")
        _ = try? self.communication.executeOnRunner(command: "open \(config.xcodePathSafe)/Contents/Developer/Applications/Simulator.app")
    }
    
    private func killSimulators() {
        self.log?.message(verboseMsg: "\(self.name) kill simulator process...")
        _ = try? self.communication.executeOnRunner(command: "osascript -e 'quit app \"Simulator\"'")
        sleep(1)
        let output = try? self.communication.executeOnRunner(command: "for p in $(pgrep -i simulator); do echo \"Terminating process: $p\"; kill -3 $p; done")
        log?.message(verboseMsg: "\(self.name): \(output?.output ?? "")")
    }

    private func getPidForProccess(name: String) -> [Int] {
        guard let result = try? self.communication.executeOnRunner(command: "pgrep -i \(name)") else {
            return []
        }
        return result.output.components(separatedBy: "\n").compactMap { Int($0) }
    }
}
