import Foundation
import CollectionConcurrencyKit

class Node {
    
    private let config: Config.NodeConfig
    private let outputDirectoryPath: String
    private let testsExecutionTimeout: Int?
    private let setUpScriptPath: String?
    private let tearDownScriptPath: String?
    
    private var executors: [TestExecutor]
    private var communication: Communication!
    private let log: Logging?
    private var finishedExecutorsCounter: Atomic<Int>
    
    let name: String
    weak var delegate: RunnerDelegate!
    
    init(config: Config.NodeConfig,
                outputDirectoryPath: String,
                testsExecutionTimeout: Int?,
                setUpScriptPath: String?,
                tearDownScriptPath: String?,
                delegate: RunnerDelegate,
                log: Logging?) throws {
        self.log = log
        self.config = config
        self.outputDirectoryPath = outputDirectoryPath
        self.testsExecutionTimeout = testsExecutionTimeout
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.executors = []
        self.name = config.name
        self.delegate = delegate
        self.finishedExecutorsCounter = Atomic(value: 0)
        
        log?.message(verboseMsg: "\(self.name) Created")
    }
}

// MARK: - Runner Protocol implementation

extension Node: Runner {
    
    func start() async {
        do {
            communication = try SSHCommunication<SSH>(host: config.host,
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
                                                            log: log)
            try communication.getBuildOnRunner(buildPath: await delegate.buildPath())
            
            let xctestrun = try await injectENVToXctestrun() // all env should be injected in to the .xctestrun file
            let xctestrunPath = try communication.saveOnRunner(xctestrun: xctestrun) // save *.xctestrun file on Node side
            
            executors = await createExecutors(xctestrunPath: xctestrunPath)
            guard !executors.isEmpty else {
                await self.delegate.runnerFinished()
                return
            }
            
            await executors.concurrentForEach { executor in
                if await executor.ready() == false {
                    // if simulator is not ready try to reset and run tests
                    // if device is not ready (doesn't plugin) - return
                    guard executor.type == .simulator else {
                        self.log?.message(verboseMsg: "\(self.name): FINISHED")
                        await self.delegate.runnerFinished()
                        return
                    }
                    await executor.reset()
                    await self.runTests(in: executor)
                } else {
                    await self.runTests(in: executor)
                }
            }
        } catch let err {
            self.log?.error("\(name): \(err)")
            await self.delegate.runnerFinished()
            return
        }
    }
}

//MARK: - Internal methods

extension Node {
    private func createExecutors(xctestrunPath: String) async -> [TestExecutor] {
        if let simulators = self.config.UDID.simulators, !simulators.isEmpty {
            return await simulators.asyncCompactMap {
                do {
					return try await Simulator(type: .simulator,
										 UDID: $0,
                                         config: self.config,
                                         xctestrunPath: xctestrunPath,
                                         setUpScriptPath: self.setUpScriptPath,
                                         tearDownScriptPath: self.tearDownScriptPath,
                                         log: log)
                } catch let err {
                    self.log?.error("\(self.name): \(err)")
                    return nil
                }
            }
        }
        
        if let devices = self.config.UDID.devices {
            return await devices.asyncCompactMap {
                do {
					return try await Device(type: .device,
									  UDID: $0,
                                      config: self.config,
                                      xctestrunPath: xctestrunPath,
                                      setUpScriptPath: self.setUpScriptPath,
                                      tearDownScriptPath: self.tearDownScriptPath,
                                      log: log)
                } catch let err {
                    self.log?.error("\(self.name): \(err)")
                    return nil
                }
            }
            
        }
		
		if let mac = self.config.UDID.mac {
			return await mac.asyncCompactMap {
				do {
					return try await Device(type: .macOS,
									  UDID: $0,
									  config: self.config,
									  xctestrunPath: xctestrunPath,
									  setUpScriptPath: self.setUpScriptPath,
									  tearDownScriptPath: self.tearDownScriptPath,
                                      log: log)
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
            await self.finish(executor)
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
            let pathToTestsResults = try self.communication.sendResultsToMaster(UDID: executor.UDID)
            await self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: pathToTestsResults)
            await self.runTests(in: executor) // continue running next tests
        } catch let err {
            self.log?.error("\(self.name): \(err)")
            await executor.reset()
            await self.runTests(in: executor)
        }
    }
    
    private func testExecutionFailureFlow(_ simError: TestExecutorError, executor: TestExecutor) async {
        switch simError {
        case .noTestsForExecution:
            self.log?.message(verboseMsg: "\(self.name): No more tests for execution")
            await self.finish(executor)
        case .executionError(let description, let tests):
            self.log?.error(description)
            await self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: nil)
            await self.runTests(in: executor) // continue running next tests
        case .testSkipped:
            self.log?.message(verboseMsg: "\(self.name): test skipped")
            await self.runTests(in: executor) // continue running next tests
        }
    }
    
    private func injectENVToXctestrun() async throws -> XCTestRun {
        var xctestrun = try await self.delegate.XCTestRun()
        self.log?.message(verboseMsg: "\(self.name): Injecting environment variables: \(self.config.environmentVariables ?? [:])")
        xctestrun.addEnvironmentVariables(self.config.environmentVariables)
        if let testsExecutionTimeout = testsExecutionTimeout {
            xctestrun.add(timeout: testsExecutionTimeout)
        }
        return xctestrun
    }
    
    private func finish(_ executor: TestExecutor) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let counter = await self.finishedExecutorsCounter.getValue()
                await self.finishedExecutorsCounter.set(value: counter + 1)
                await executor.reset()
                self.log?.message(verboseMsg: "\(self.name) \(executor.type.rawValue): \"\(executor.UDID)\") finished")
                if await self.finishedExecutorsCounter.getValue() == self.executors.count {
                    self.log?.message(verboseMsg: "\(self.name): FINISHED")
                    await self.delegate.runnerFinished()
                }
            }
        }
    }
    
    private func killSimulators() {
        let simulators = self.executors.filter { $0.type == .simulator }
        guard !simulators.isEmpty else { return }
        
        self.log?.message(verboseMsg: "\(self.name) kill simulator process...")
        guard let pid = self.getIdForProccess(name: "com.apple.CoreSimulator.CoreSimulatorService") else {
            return
        }
        let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePathSafe)/Contents/Developer\n"
        let killCommands = prefixCommand + "kill -3 \(pid)"
        let bootCommands = prefixCommand +
            simulators
            .map { return "xcrun simctl boot \($0.UDID)" }
            .joined(separator: "\n")
        sleep(5)
        _ = try? self.communication.executeOnRunner(command: killCommands)
        sleep(5)
        _ = try? self.communication.executeOnRunner(command: bootCommands)
    }

    private func getIdForProccess(name: String) -> Int? {
        guard let result = try? self.communication.executeOnRunner(command: "ps axc -o pid -o command | grep -E '\(name)' | grep -Eoi -m 1 '[0-9]' | tr -d '\n'") else {
            return nil
        }
        return Int(result.output)
    }
}
