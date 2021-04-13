import Foundation

class Node {
    
    private let config: Config.NodeConfig
    private let outputDirectoryPath: String
    private let testsExecutionTimeout: Int
    private let setUpScriptPath: String?
    private let tearDownScriptPath: String?
    
    private var executors: [TestExecutor]
    private let queue: Queue
    private let serialQueue: Queue
    private var communication: Communication!
    private var _finished: Bool = false
    
    let name: String
    weak var delegate: RunnerDelegate!
    var finished: Bool {
        get {
            self.queue.sync(flags: .barrier) { self._finished }
        }
        set {
            self.queue.async(flags: .barrier) { self._finished = newValue }
        }
    }
    
    init(config: Config.NodeConfig,
                outputDirectoryPath: String,
                testsExecutionTimeout: Int,
                setUpScriptPath: String?,
                tearDownScriptPath: String?,
                delegate: RunnerDelegate) throws {
        self.config = config
        self.outputDirectoryPath = outputDirectoryPath
        self.testsExecutionTimeout = testsExecutionTimeout
        self.setUpScriptPath = setUpScriptPath
        self.tearDownScriptPath = tearDownScriptPath
        self.executors = []
        self.queue = .init(type: .concurrent, name: "io.engenious." + config.name + "." + config.host)
        self.serialQueue = .init(type: .serial, name: "io.engenious." + config.name + "." + config.host + ".serial")
        self.name = config.name
        self.delegate = delegate
    }
}

// MARK: - Runner Protocol implementation

extension Node: Runner {
    func start() {
        self.queue.async {
            do {
                self.communication = try SSHCommunication<SSH>(host: self.config.host,
                                                               port: self.config.port,
                                                           username: self.config.username,
                                                           password: self.config.password,
                                                         privateKey: self.config.privateKey,
                                                          publicKey: self.config.publicKey,
                                                         passphrase: self.config.passphrase,
                                               runnerDeploymentPath: self.config.deploymentPath,
                                               masterDeploymentPath: self.outputDirectoryPath,
                                                           nodeName: self.config.name)
                try self.communication.getBuildOnRunner(buildPath: self.delegate.buildPath())
                
                let xctestrun = self.injectENVToXctestrun() // all env should be injected in to the .xctestrun file
                let xctestrunPath = try self.communication.saveOnRunner(xctestrun: xctestrun) // save *.xctestrun file on Node side
                
                self.executors = self.createExecutors(xctestrunPath: xctestrunPath)
                self.executors.forEach { executor in
                    executor.ready { result in
                        if result == false {
                            // if simulator is not ready try to reset and run tests
                            // if device is not ready (doesn't plugin) - return
                            guard executor.type == .simulator else { return }
                            executor.reset { _ in
                                self.runTests(in: executor)
                            }
                        } else {
                            self.runTests(in: executor)
                        }
                    }
                }
            } catch let err {
                Log.error("\(self.name): \(err)")
                return
            }
        }
    }
}

//MARK: - Internal methods

extension Node {
    private func createExecutors(xctestrunPath: String) -> [TestExecutor] {
        if let simulators = self.config.UDID.simulators, !simulators.isEmpty {
            return simulators.compactMap {
                do {
					return try Simulator(type: .simulator,
										 UDID: $0,
                                         config: self.config,
                                         xctestrunPath: xctestrunPath,
                                         setUpScriptPath: self.setUpScriptPath,
                                         tearDownScriptPath: self.tearDownScriptPath)
                } catch let err {
                    Log.error("\(self.name): \(err)")
                    return nil
                }
            }
        }
        
        if let devices = self.config.UDID.devices {
            return devices.compactMap {
                do {
					return try Device(type: .device,
									  UDID: $0,
                                      config: self.config,
                                      xctestrunPath: xctestrunPath,
                                      setUpScriptPath: self.setUpScriptPath,
                                      tearDownScriptPath: self.tearDownScriptPath)
                } catch let err {
                    Log.error("\(self.name): \(err)")
                    return nil
                }
            }
        }
		
		if let mac = self.config.UDID.mac {
			return mac.compactMap {
				do {
					return try Device(type: .macOS,
									  UDID: $0,
									  config: self.config,
									  xctestrunPath: xctestrunPath,
									  setUpScriptPath: self.setUpScriptPath,
									  tearDownScriptPath: self.tearDownScriptPath)
				} catch let err {
					Log.error("\(self.name): \(err)")
					return nil
				}
			}
		}
        return []
    }
    
    private func runTests(in executor: TestExecutor) {
        let testsForExecution = self.delegate.getTests() // request tests for execution
        if testsForExecution.isEmpty {
            self.finish(executor)
            return
        }
        executor.run(tests: testsForExecution,
                   timeout: self.testsExecutionTimeout,
                completion: { [unowned self] (executor, result) in
            /*
             .success - doesn't mean that tests is passed, just means that tests was successfully executed
             .failure - tests was not executed.
            */
            self.queue.async {
                switch result {
                case .success(let tests):
                    self.testExecutionSuccessFlow(tests, executor: executor)
                case .failure(let error):
                    self.testExecutionFailureFlow(error, executor: executor)
                }
            }
        })
    }
    
    private func testExecutionSuccessFlow(_ tests: [String], executor: TestExecutor) {
        do {
            let pathToTestsResults = try self.communication.sendResultsToMaster(UDID: executor.UDID)
            self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: pathToTestsResults)
            self.runTests(in: executor) // continue running next tests
        } catch let err {
            Log.error("\(self.name): \(err)")
            executor.reset { _ in
                self.runTests(in: executor)
            }
        }
    }
    
    private func testExecutionFailureFlow(_ simError: TestExecutorError, executor: TestExecutor) {
        switch simError {
        case .noTestsForExecution:
            self.finish(executor)
        case .executionError(let description, let tests):
            Log.error(description)
            self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: nil)
            self.runTests(in: executor) // continue running next tests
        case .testSkipped:
            self.runTests(in: executor) // continue running next tests
        }
    }
    
    private func injectENVToXctestrun() -> XCTestRun {
        var xctestrun = self.delegate.XCTestRun()
        xctestrun.addEnvironmentVariables(self.config.environmentVariables)
        return xctestrun
    }
    
    private func finish(_ executor: TestExecutor) {
        executor.reset(completion: nil)
        self.serialQueue.async {
            Log.message(verboseMsg: "\(self.name) Simulator: \"\(executor.UDID)\") finished")
            executor.finished = true
            if (self.executors.filter { $0.finished == false }).count == 0 {
                //self.killSimulators()
                Log.message(verboseMsg: "\(self.name): FINISHED")
                self.delegate.runnerFinished(runner: self)
            }
        }
    }
    
    private func killSimulators() {
        let simulators = self.executors.filter { $0.type == .simulator }
        guard !simulators.isEmpty else { return }
        
        Log.message(verboseMsg: "\(self.name) kill simulator process...")
        guard let pid = self.getIdForProccess(name: "com.apple.CoreSimulator.CoreSimulatorService") else {
            return
        }
        let prefixCommand = "export DEVELOPER_DIR=\(self.config.xcodePath)/Contents/Developer\n"
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
