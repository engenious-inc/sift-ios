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
                                                      username: config.authorization.data.username,
                                                      password: config.authorization.data.password,
                                                      privateKey: config.authorization.data.privateKey,
                                                      publicKey: config.authorization.data.publicKey, // not implemented on backend
                                                      passphrase: config.authorization.data.passphrase,
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
                if await executor.ready() {
                    await self.runTests(in: executor)
                } else {
                    await self.finish(executor, reset: false)
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
                                         runnerDeploymentPath: config.deploymentPath,
                                         masterDeploymentPath: outputDirectoryPath,
                                         nodeName: config.name,
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
                                      runnerDeploymentPath: config.deploymentPath,
                                      masterDeploymentPath: outputDirectoryPath,
                                      nodeName: config.name,
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
                                      runnerDeploymentPath: config.deploymentPath,
                                      masterDeploymentPath: outputDirectoryPath,
                                      nodeName: config.name,
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
            await self.finish(executor)
        case .executionError(let description, let tests):
            self.log?.error(description)
            await self.delegate.handleTestsResults(runner: self, executedTests: tests, pathToResults: nil)
            if await executor.executionFailureCounter.getValue() < 2 {
                await self.runTests(in: executor) // continue running next tests
            } else {
                await self.finish(executor)
            }
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
    
    private func finish(_ executor: TestExecutor, reset: Bool = true) async {
        self.log?.message(verboseMsg: "\(self.name) \(executor.type.rawValue): \"\(executor.UDID)\") finished")
        let counter = await self.finishedExecutorsCounter.increment()
        if counter == self.executors.count {
            self.log?.message(verboseMsg: "\(self.name): FINISHED")
            killSimulators()
            await executors.concurrentForEach {
                await $0.reset()
            }
            launchSimulator()
            await self.delegate.runnerFinished()
        }
    }
    
    private func launchSimulator() {
        log?.message(verboseMsg: "Launch: \(config.xcodePathSafe)/Contents/Developer/Applications/Simulator.app")
        _ = try? self.communication.executeOnRunner(command: "open \(config.xcodePathSafe)/Contents/Developer/Applications/Simulator.app")
    }
    
    private func killSimulators() {
        let simulators = self.executors.filter { $0.type == .simulator }
        guard !simulators.isEmpty else { return }
        
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
