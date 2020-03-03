import Foundation


public class Controller {
    private let config: Config
    private let xctestrun: XCTestRun
    private var runners: [Runner] = []
    public var testsNames: [String]
    private var testsForRerun: [String] = []
    private var testsLaunchCounter: [String: Int] = [:]
    private var testsIterator: IndexingIterator<[String]>
    private let shell: ShellExecutor
    private let serialQueue: Queue
    private let time = Date.timeIntervalSinceReferenceDate
    private var zipBuildPath: String? = nil
    private var xcresultFiles: [String] = []
    private lazy var xcresulttool = XCResultTool(shell: self.shell)

    public init(config: Config, tests: [String]? = nil, shell: ShellExecutor = Run()) throws {
        self.config = config
        self.xctestrun = try .init(path: config.xctestrunPath)
        
        let bundleTests = self.xctestrun.testBundleExecPaths().flatMap { (key: String, value: String) -> [String] in
            do {
                let listOfTests: [String] = try TestsDump().dump(path: value, moduleName: key)
                log("\(key): \(listOfTests.count) tests")
                return listOfTests
            } catch let err {
                error("\(err)")
                return []
            }
        }
        
        self.testsNames = tests != nil && !tests!.isEmpty ? tests! : bundleTests
        self.testsNames.shuffle()
        self.testsIterator = self.testsNames.makeIterator()
        self.shell = shell
        self.serialQueue = .init(type: .serial, name: "TestsProcessorSerialQueue")
        
        log("Total tests for execution: \(self.testsNames.count)")
    }
    
    public func start() {
        self.serialQueue.async {
            do {
                _ = try? self.shell.run("mkdir \(self.config.outputDirectoryPath)")
                _ = try? self.shell.run("rm -r \(self.config.outputDirectoryPath)/*")
                try self.zipBuildPath = self.zipBuild()
                self.runners = RunnersFactory.create(config: self.config, delegate: self)
                self.runners.forEach {
                    $0.start()
                }
            } catch let err {
                error("\(err)")
            }
        }
    }
}

//MARK: - private methods
extension Controller {
    private func zipBuild() throws -> String {
        var filesToZip: [String] = self.xctestrun.dependentProductPathsCuted().compactMap { (path) -> String? in
            path.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: "")
        }

        filesToZip.append(config.xctestrunPath.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: ""))
        try self.shell.run(Scripts.zip(workdirectory: self.xctestrun.testRootPath, zipName: "build.zip", files: filesToZip))
        return "\(self.xctestrun.testRootPath)/build.zip"
    }
    
    private func checkout(runner: Runner) {
        if (self.runners.filter { $0.finished == false }).count == 0 {
            let mergedResultsPath = "'\(self.config.outputDirectoryPath)/final/final_result.xcresult'"
            do {
                try self.xcresulttool.merge(inputPaths: self.xcresultFiles,
                               outputPath: mergedResultsPath)
                let xcresult = XCResult(path: mergedResultsPath, tool: self.xcresulttool)
                let testsCount = try xcresult.actionsInvocationRecord().metrics.testsCount
                let failedTests = try xcresult.failedTests()
                let reran = try xcresult.reran()
                
                print("")
                log("####################################\n")
                log("Total Tests: \(testsCount)")
                log("Passed: \(testsCount - failedTests.count) tests")
                log("Reran: \(reran.count) tests")
                reran.forEach {
                    warning(before: "\t", "\($0.key) - \($0.value) times")
                }
                log("Failed: \(failedTests.count) tests")
                failedTests.forEach {
                    failed(before: "\t", $0.identifier ?? "")
                }
                log("Done: in \(String(format: "%.3f", Date.timeIntervalSinceReferenceDate - self.time)) seconds")
                print()
                log("####################################")
                
                if failedTests.count == 0 {
                    exit(0)
                }
                exit(1)
            } catch let err {
                error("\(err)")
                exit(1)
            }
        }
    }
    
    private func getTestForRerun() -> String? {
        return self.testsForRerun.popLast()
    }
    
    private func addForRerun(test: String) {
        self.testsLaunchCounter[test, default: 0] += 1
        if self.testsLaunchCounter[test]! <= self.config.rerunFailedTest {
            self.testsForRerun.append(test)
            self.testsForRerun.shuffle()
        }
    }
    
    private func getXCResult(path: String) -> XCResult? {
        do {
            let uuid = UUID().uuidString
            let unzipFolderPath = "\(self.config.outputDirectoryPath)/\(uuid)"
            try self.shell.run("unzip \"\(path)\" -d \(unzipFolderPath)")
            let files = try self.shell.run("ls -1 \(unzipFolderPath) | grep -E '.\\.xcresult$'").output
            let xcresultFiles =  files.components(separatedBy: "\n")
            guard let xcresultFileName = (xcresultFiles.filter { $0.contains(".xcresult") }.sorted { $0 > $1 }).first else {
                error("*.xcresult files was not found: \(unzipFolderPath)")
                return nil
            }
            
            let xcresultAbsolutePath = "\(unzipFolderPath)/\(xcresultFileName)"
            _ = try? self.shell.run("mkdir \(self.config.outputDirectoryPath)/final")
            try self.shell.run("cp -R '\(xcresultAbsolutePath)' " +
                               "'\(self.config.outputDirectoryPath)/final/\(uuid).xcresult'")
            self.xcresultFiles.append("\(self.config.outputDirectoryPath)/final/\(uuid).xcresult")
            let xcresult = XCResult(path: "\(self.config.outputDirectoryPath)/final/\(uuid).xcresult",
                tool: xcresulttool)
            _ = try? self.shell.run("rm -r '\(unzipFolderPath)'")
            _ = try? self.shell.run("rm -r '\(path)'")
            
            return xcresult
        } catch let err {
            error("\(err)")
            return nil
        }
    }
    
    private func printUnknown(runnerName: String, tests: [String]) {
        tests.forEach {
            failed("\(runnerName): \($0) - Was not executed")
            self.addForRerun(test: $0)
        }
    }
    
    private func printSuccess(runnerName: String, tests: [ActionTestMetadata]) {
        tests.forEach {
            success("\(runnerName): \($0.identifier ?? "") " +
                    "- \($0.testStatus): \(String(format: "%.3f", $0.duration ?? 0)) sec.")
        }
    }
    
    private func printFailed(runnerName: String, tests: [ActionTestMetadata]) {
        tests.forEach {
            failed("\(runnerName): \($0.identifier ?? "") " +
                   "- \($0.testStatus): \(String(format: "%.3f", $0.duration ?? 0)) sec.")
            if let testId = $0.identifier {
                self.addForRerun(test: testId)
            }
        }
    }
}

//MARK: - TestsRunnerDelegate implementation
extension Controller: RunnerDelegate {
    public func runnerFinished(runner: Runner) {
        self.serialQueue.async {
            self.checkout(runner: runner)
        }
    }
    
    public func handleTestsResults(runner: Runner, tests: [String], pathToResults: String?) {
        self.serialQueue.async {
            guard let pathToResults = pathToResults,
                  let xcresult = self.getXCResult(path: pathToResults) else {
                    self.printUnknown(runnerName: runner.name, tests: tests)
                return
            }
            
            do {
                let testMetadata = try xcresult.testsMetadata()
                let testsId = testMetadata.compactMap { $0.identifier }
                let unknownTests = tests.filter { !testsId.contains($0)  }
                self.printUnknown(runnerName: runner.name, tests: unknownTests)
                
                testMetadata.forEach {
                    if $0.testStatus == "Success" {
                        self.printSuccess(runnerName: runner.name, tests: [$0])
                    } else {
                        self.printFailed(runnerName: runner.name, tests: [$0])
                    }
                }
            } catch let err {
                error("\(err)")
            }
        }
    }
    
    public func XCTestRun() -> XCTestRun {
        return self.serialQueue.sync { self.xctestrun }
    }
    
    public func buildPath() -> String {
        return self.serialQueue.sync { self.zipBuildPath! }
    }
    
    public func getTests() -> [String] {
        return self.serialQueue.sync {
            var tests: [String] = []
            for _ in 1...self.config.testsBucket {
                guard let test = self.testsIterator.next() else {
                    break
                }
                tests.append(test)
            }
            if tests.isEmpty, let testForRerun = self.getTestForRerun() {
                tests.append(testForRerun)
            }
            return tests
        }
    }
}
