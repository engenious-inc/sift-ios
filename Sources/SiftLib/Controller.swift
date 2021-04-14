import Foundation

public class Controller {
    private let config: Config
    private let xctestrun: XCTestRun
    private var runners: [Runner] = []
    private let queue: Queue
    private let time = Date.timeIntervalSinceReferenceDate
    private var zipBuildPath: String? = nil
    private var xcresultFiles: [String] = []
    private var xcresulttool: XCResultTool!
    private(set) var tests: TestCases
    private var testRunID: Int?
    private var orchestrator: OrchestratorAPI?
    
    @discardableResult
    public static func bundleTests(xctestrunPath: String, block: ((String, Int)->Void)? = nil) throws -> [String] {
        try SiftLib.XCTestRun(path: xctestrunPath)
            .testBundleExecPaths().flatMap { (key: String, value: String) -> [String] in
            do {
                let listOfTests: [String] = try TestsDump().dump(path: value, moduleName: key)
                block?(key, listOfTests.count)
                return listOfTests
            } catch let err {
                Log.error("\(err)")
                return []
            }
        }
    }
    
    public init(config: Config, tests: [String]? = nil) throws {
        self.config = config
        self.xctestrun = try .init(path: config.xctestrunPath)
        let bundleTests = try Self.bundleTests(xctestrunPath: config.xctestrunPath) {
            Log.message("\($0): \($1) tests")
        }
        self.tests = TestCases(tests: (tests != nil && !tests!.isEmpty ? tests! : bundleTests).shuffled(),
                               rerunLimit: config.rerunFailedTest)
        self.queue = .init(type: .serial, name: "io.engenious.TestsProcessor")
    }

    public init(config: Config, orchestrator: OrchestratorAPI) throws {
        self.config = config
        self.orchestrator = orchestrator
        self.xctestrun = try .init(path: config.xctestrunPath)
        try Self.bundleTests(xctestrunPath: config.xctestrunPath) {
            Log.message("\($0): \($1) tests")
        }
        self.tests = TestCases(tests: config.tests?.shuffled() ?? [],
                               rerunLimit: config.rerunFailedTest)
        self.queue = .init(type: .serial, name: "io.engenious.TestsProcessor")
    }
    
    public func start() {
        self.queue.sync {
            do {
                let shell = Run()
                self.xcresulttool = XCResultTool()
                Log.message("Total tests for execution: \(self.tests.count)")
                Log.message(verboseMsg: "Clean: \(self.config.outputDirectoryPath)")
                _ = try? shell.run("mkdir \(self.config.outputDirectoryPath)")
                _ = try? shell.run("rm -r \(self.config.outputDirectoryPath)/*")
                try self.zipBuildPath = self.zipBuild()
                self.runners = RunnersFactory.create(config: self.config, delegate: self)
                self.runners.forEach {
                    $0.start()
                }
            } catch let err {
                Log.error("\(err)")
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
        Log.message(verboseMsg: "Start zip dependent files: \n\t\t- " + filesToZip.joined(separator: "\n\t\t- "))
        try Run().run(Scripts.zip(workdirectory: self.xctestrun.testRootPath,
                                       zipName: "build.zip",
                                       files: filesToZip))
        let zipPath = "\(self.xctestrun.testRootPath)/build.zip"
        Log.message(verboseMsg: "Zip path: " + zipPath)
        return zipPath
    }
    
    private func getXCResult(path: String) -> XCResult? {
        do {
            let shell = Run()
            let uuid = UUID().uuidString
            let unzipFolderPath = "\(self.config.outputDirectoryPath)/\(uuid)"
            try shell.run("unzip -o -q \"\(path)\" -d \(unzipFolderPath)")
            let files = try shell.run("ls -1 \(unzipFolderPath) | grep -E '.\\.xcresult$'").output
            let xcresultFiles =  files.components(separatedBy: "\n")
            guard let xcresultFileName = (xcresultFiles.filter { $0.contains(".xcresult") }.sorted { $0 > $1 }).first else {
                Log.error("*.xcresult files was not found: \(unzipFolderPath)")
                return nil
            }
            
            let xcresultAbsolutePath = "\(unzipFolderPath)/\(xcresultFileName)"
            _ = try? shell.run("mkdir \(self.config.outputDirectoryPath)/final")
            try shell.run("cp -R '\(xcresultAbsolutePath)' " +
                               "'\(self.config.outputDirectoryPath)/final/\(uuid).xcresult'")
            self.xcresultFiles.append("\(self.config.outputDirectoryPath)/final/\(uuid).xcresult")
            let xcresult = XCResult(path: "\(self.config.outputDirectoryPath)/final/\(uuid).xcresult",
                tool: xcresulttool)
            _ = try? shell.run("rm -r '\(unzipFolderPath)'")
            _ = try? shell.run("rm -r '\(path)'")
            
            return xcresult
        } catch let err {
            Log.error("\(err)")
            return nil
        }
    }
    
    private func checkout(runner: Runner) {
        runner.finished = true
        if (self.runners.filter { $0.finished == false }).count == 0 {
            Log.message(verboseMsg: "All nodes finished")
            let mergedResultsPath = "'\(self.config.outputDirectoryPath)/final/final_result.xcresult'"
            let JUnitReportUrl = URL(fileURLWithPath: "\(self.config.outputDirectoryPath)/final/final_result.xml")
            do {
                Log.message(verboseMsg: "Merging results...")
                if let mergeXCResult = try? self.xcresulttool.merge(inputPaths: self.xcresultFiles, outputPath: mergedResultsPath), mergeXCResult.status != 0 {
                    Log.message(verboseMsg: mergeXCResult.output)
                } else {
                    Log.message(verboseMsg: "All results is merged: \(mergedResultsPath)")
                }
                try JUnit().generate(tests: self.tests).write(to: JUnitReportUrl, atomically: true, encoding: .utf8)
                let reran = self.tests.reran
                let failed = self.tests.failed
                let unexecuted = self.tests.unexecuted
                quiet = false
                print()
                Log.message("####################################\n")
                Log.message("Total Tests: \(self.tests.count)")
                Log.message("Passed: \(self.tests.passed.count) tests")
                Log.message("Reran: \(reran.count) tests")
                reran.forEach {
                    Log.warning(before: "\t", "\($0.name) - \($0.launchCounter - 1) times")
                }
                Log.message("Failed: \(failed.count) tests")
                failed.forEach {
                    Log.failed(before: "\t", $0.name)
                }
                Log.message("Unexecuted: \(unexecuted.count) tests")
                unexecuted.forEach {
                    Log.failed(before: "\t", $0.name)
                }
                let seconds = Date.timeIntervalSinceReferenceDate - self.time
                Log.message("Done: in \(String(format: "%.3f", seconds)) seconds")
                print()
                Log.message("####################################")

                if let orchestrator = self.orchestrator {
                    let testRun = orchestrator.postRun()

                    guard let runIndex = testRun?.runIndex else {
                        Log.error("Run ID was not found")
                        return
                    }
                    Log.message("Creating test run for orchestrator ...")

                    if orchestrator.postResults(testResults: formResults(runIndex: runIndex)) {
                        Log.message("Results posted successfully!")
                    } else {
                        Log.error("Faild to post results.")
                    }

                    var snapshots: [String] = []
                    for test in self.tests.failed {
                        if let screenshotID = test.screenshotID {
                            let extractedPng = extractImage(xcresultPath: mergedResultsPath, testName: test.name, screenshotID: screenshotID)
                            snapshots.append(extractedPng)
                        }
                    }
                    if orchestrator.postImages(runIndex: runIndex, fileNames: snapshots) {
                        Log.message("Screenshots posted successfully!")
                    } else {
                        Log.error("Faild to post screenshots.")
                    }
                }
                if failed.count == 0 && unexecuted.count == 0 {
                    exit(0)
                }
                exit(1)
            } catch let err {
                Log.error("\(err)")
                exit(1)
            }
        }
    }
}

//MARK: - TestsRunnerDelegate implementation
extension Controller: RunnerDelegate {
    public func runnerFinished(runner: Runner) {
        self.queue.async {
            self.checkout(runner: runner)
        }
    }

    public func handleTestsResults(runner: Runner, executedTests: [String], pathToResults: String?) {
        self.queue.async {
            Log.message(verboseMsg: "Parse test results from \(runner.name)")
            guard let pathToResults = pathToResults,
                  var xcresult = self.getXCResult(path: pathToResults) else {
                executedTests.forEach {
                    self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
                    Log.failed("\(runner.name): \($0) - Was not executed")
                }
                return
            }
           
            do {
                let testsMetadata = try xcresult.testsMetadata()
                    .reduce(into: [String: ActionTestMetadata]()) { dictionary, value in
                        dictionary[value.identifier] = value
                }

                try executedTests.forEach {
                    guard let testMetaData = testsMetadata[$0] else {
                        self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
                        Log.failed("\(runner.name): \($0) - Was not executed")
                        return
                    }
                    if testMetaData.testStatus == "Success" {
                        self.tests.update(test: $0, state: .pass, duration: testMetaData.duration ?? 0.0)
                        Log.success("\(runner.name): \($0) " +
                        "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
                    } else {
                        let summary: ActionTestSummary = try xcresult.modelFrom(reference: testMetaData.summaryRef!)
                        var message = summary.failureSummaries.compactMap { $0.message }.joined(separator: " ")
                        let allChildActivities = summary.allChildActivitySummaries().filter {$0.activityType == "com.apple.dt.xctest.activity-type.testAssertionFailure"}
                        
                        if message.isEmpty {
                            message = allChildActivities.map { $0.title }.joined(separator: "\n")
                        }
                        
                        Log.failed("\(runner.name): \($0) " +
                        "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
                        Log.message(verboseMsg: "\(runner.name): \($0) - \(testMetaData.testStatus):\n\t\t- \(message)")
                        
                        let screenshotID = allChildActivities.flatMap { $0.attachments }.last?.payloadRef?.id
                        
                        self.tests.update(test: $0,
                                          state: .failed,
                                          duration: testMetaData.duration ?? 0.0,
                                          message: message,
                                          screenshotID: screenshotID
                        )
                    }
                }
            } catch let err {
                Log.error("\(err)")
            }
        }
    }
    
    public func XCTestRun() -> XCTestRun {
        return self.queue.sync { self.xctestrun }
    }
    
    public func buildPath() -> String {
        return self.queue.sync { self.zipBuildPath! }
    }
    
    public func getTests() -> [String] {
        self.queue.sync {
            var testsForExecution = self.tests.next(amount: self.config.testsBucket)
            if testsForExecution.isEmpty, let testForRerun = self.tests.nextForRerun() {
                testsForExecution.append(testForRerun)
            }
            return testsForExecution
        }
    }
    
    public func formResults(runIndex: Int) -> OrchestratorTestResults {
        let results =  self.tests.cases.map {
            OrchestratorTestResults.TestResult(testId: $0.value.id ?? 0,
                                               result: $0.value.resultFormatted(),
                                               errorMessage: $0.value.message)
        }
        return OrchestratorTestResults(runIndex: runIndex, testResults: results)
    }
    
    func extractImage(xcresultPath: String, testName: String, screenshotID: String) -> String {
        let directory = xcresultPath.split(separator: "/").dropLast(1).map(String.init).joined(separator: "/") + "/"
        
        let shell = Run()
        let fileName = testName.replacingOccurrences(of: "/", with: "")
                               .replacingOccurrences(of: "()", with: "")
                               .appending(".jpeg")
        let fileLocation = "\(directory)\(fileName)\'"
        // Extract files
        do {
            try xcresulttool.export(id: screenshotID, outputPath: fileLocation, xcresultPath: xcresultPath, type: .file)
        } catch {
            Log.error("Can not extract data from xcresult")
        }
        // Convert to .PNG
        let pngFileLocation = "\(directory)\(config.getTestId(testName: testName) ?? 0).png\'"
        do {
            try shell.run("sips -s format png \(fileLocation) --out \(pngFileLocation)")
        } catch {
            Log.error("Error while converting .jpeg to .png")
        }
        return pngFileLocation
    }
}
