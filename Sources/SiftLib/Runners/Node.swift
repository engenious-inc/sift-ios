import Foundation

class Node {
    
    private let config: Config.NodeConfig
    private let outputDirectoryPath: String
    private let testsExecutionTimeout: Int
    private let setUpScriptPath: String?
    private let tearDownScriptPath: String?
    
    private var executors: [TestExecutor]
    private let serialQueue: Queue
    private var communication: Communication!
    
    private let _name: String
    private var _finished: Bool
    private weak var _delegate: RunnerDelegate!
    
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
        self.serialQueue = .init(type: .serial, name: config.name + "-" + config.host)
        
        self._name = config.name
        self._finished = false
        self._delegate = delegate
    }
}

// MARK: - Runner Protocol implementation

extension Node: Runner {
    var name: String { _name }
    var finished: Bool { _finished }
    var delegate: RunnerDelegate { _delegate }
    
    func start() {
        self.serialQueue.async {
            do {
                self.communication = try SSHCommunication<SSH>(host: self.config.host,
                                                               port: self.config.port,
                                                           username: self.config.username,
                                                           password: self.config.password,
                                               runnerDeploymentPath: self.config.deploymentPath,
                                               masterDeploymentPath: self.outputDirectoryPath)
                try self.communication.getBuildOnRunner(buildPath: self.delegate.buildPath())
                let xctestrun = self.injectENVToXctestrun() // all env should be injected in to the .xctestrun file
                let xctestrunPath = try self.communication.saveOnRunner(xctestrun: xctestrun) // save *.xctestrun file on Node side
                
                self.executors = self.createExecutors(xctestrunPath: xctestrunPath)
                self.executors.forEach { executor in
                    executor.ready { result in
                        if !result {
                            guard executor.type == .simulator else { return }
                            executor.reset(completion: nil)
                        }
                        self.runTests(in: executor)
                    }
                    
                }
            } catch let err {
                error("\(self.name): \(err)")
                return
            }
        }
    }
}

//MARK: - Internal methods

extension Node {
    private func createExecutors(xctestrunPath: String) -> [TestExecutor] {
        if let simulators = self.config.UDID.simulators {
            return simulators.compactMap {
                do {
                    return try Simulator(UDID: $0,
                                         config: self.config,
                                         xctestrunPath: xctestrunPath,
                                         setUpScriptPath: self.setUpScriptPath,
                                         tearDownScriptPath: self.tearDownScriptPath)
                } catch let err {
                    error("\(self.name): \(err)")
                    return nil
                }
            }
        }
        
        if let devices = self.config.UDID.devices {
            return devices.compactMap {
                do {
                    return try Device(UDID: $0,
                                      config: self.config,
                                      xctestrunPath: xctestrunPath,
                                      setUpScriptPath: self.setUpScriptPath,
                                      tearDownScriptPath: self.tearDownScriptPath)
                } catch let err {
                    error("\(self.name): \(err)")
                    return nil
                }
            }
        }
        return []
    }
    
    private func runTests(in executor: TestExecutor) {
        let testsForExecution = self.delegate.getTests() // request tests for execution
        executor.run(tests: testsForExecution,
                   timeout: self.testsExecutionTimeout,
                completion: { [unowned self] (executor, result) in
            /*
             .success - doesn't mean that tests is passed, just means that tests was successfully executed
             .failure - tests was not executed.
            */
            self.serialQueue.async {
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
            self.delegate.handleTestsResults(runner: self, tests: tests, pathToResults: pathToTestsResults)
            self.runTests(in: executor) // continue running next tests
        } catch let err {
            error("\(self.name): \(err)")
        }
    }
    
    private func testExecutionFailureFlow(_ simError: TestExecutorError, executor: TestExecutor) {
        switch simError {
        case .noTestsForExecution:
            self.checkIfFinished()
        case .executionError(let description, let tests):
            error(description)
            self.delegate.handleTestsResults(runner: self, tests: tests, pathToResults: nil)
            self.runTests(in: executor) // continue running next tests
        case .testSkipped:
            self.runTests(in: executor) // continue running next tests
        }
    }
    
    private func injectENVToXctestrun() -> XCTestRun {
        var xctestrun = self.delegate.XCTestRun()
        xctestrun.addEnvironmentVariables(self.config.environmentVariables ?? [:])
        return xctestrun
    }
    
    private func checkIfFinished() {
        if (self.executors.filter { $0.finished == false }).count == 0 {
            self._finished = true
            self.executors.forEach { $0.reset(completion: nil) }
            self.delegate.runnerFinished(runner: self)
        }
    }
}
