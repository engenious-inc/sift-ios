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
    public var tests: TestCases
    public private(set) var bundleTests: [String]
    private let log: Logging?

    public init(config: Config, tests: [String]? = nil, log: Logging?) throws {
        self.log = log
        self.config = config
        let xctestrun = try XCTestRunFactory.create(path: config.xctestrunPath, log: log)
		self.xctestrun = xctestrun
        self.bundleTests = self.xctestrun.testBundleExecPaths.flatMap { bundle -> [String] in
            let moduleName = bundle.path.components(separatedBy: "/").last ?? bundle.target
            do {
				let listOfTests: [String] = try TestsDump().dump(path: bundle.path, moduleName: moduleName)
                log?.message("\(moduleName): \(listOfTests.count) tests")
                return listOfTests
            } catch {
                log?.warning("Target: \(moduleName) - tests not found")
                return []
            }
		}

		if !xctestrun.onlyTestIdentifiers.isEmpty {
            log?.message(verboseMsg: "xctestrun.onlyTestIdentifiers:\n" + xctestrun.onlyTestIdentifiers.description)
			// remove tests which not included in xctestrun.onlyTestIdentifiers
			self.bundleTests.removeAll {
				var bundleTestComponents = $0.components(separatedBy: "/")
                let moduleName = bundleTestComponents.removeFirst().replacingOccurrences(of: " ", with: "_")
				guard let moduleTest = xctestrun.onlyTestIdentifiers[moduleName], !moduleTest.isEmpty else { return false }
				return moduleTest.first {
					let isOnlyTestIdentifierContainsInBundleTests = $0.components(separatedBy: "/").enumerated().allSatisfy {
						$0.element == bundleTestComponents[$0.offset].replacingOccurrences(of: "()", with: "")
					}
					return isOnlyTestIdentifierContainsInBundleTests
				} == nil
			}
		}
		
		if !xctestrun.skipTestIdentifiers.isEmpty {
            log?.message(verboseMsg: "xctestrun.skipTestIdentifiers:\n" + xctestrun.skipTestIdentifiers.description)
			// remove tests which included in xctestrun.skipTestIdentifiers
			self.bundleTests.removeAll {
				var bundleTestComponents = $0.components(separatedBy: "/")
                let moduleName = bundleTestComponents.removeFirst().replacingOccurrences(of: " ", with: "_")
				return xctestrun.skipTestIdentifiers[moduleName]?.first {
					let isSkipTestIdentifiersContainsInBundleTests = $0.components(separatedBy: "/").enumerated().allSatisfy {
						$0.element == bundleTestComponents[$0.offset].replacingOccurrences(of: "()", with: "")
					}
					return isSkipTestIdentifiersContainsInBundleTests
				} != nil
			}
		}
		
        self.tests = TestCases(tests: (tests != nil && !tests!.isEmpty ? tests! : bundleTests).shuffled(),
                               rerunLimit: config.rerunFailedTest)
        self.queue = .init(type: .serial, name: "io.engenious.TestsProcessor")
    }
    
    public func start() {
        self.queue.sync { [self] in
            do {
                let shell = Run()
                self.xcresulttool = XCResultTool()
                log?.message("Total tests for execution: \(self.tests.count)")
                log?.message(verboseMsg: "Create/Clean: \(self.config.outputDirectoryPath)")
                _ = try? shell.run("mkdir \(self.config.outputDirectoryPath)")
                _ = try? shell.run("rm -r \(self.config.outputDirectoryPath)/*")
                try self.zipBuildPath = self.zipBuild()
                self.runners = RunnersFactory.create(config: self.config, delegate: self, log: log)
                self.runners.forEach {
                    $0.start()
                }
            } catch let err {
                log?.error("\(err)")
            }
        }
    }
}

//MARK: - private methods
extension Controller {
    private func zipBuild() throws -> String {
        let filesToZip: [String] = self.xctestrun.dependentProductPaths.compactMap { (path) -> String? in
			var path = path
			if path.contains("-Runner.app") {
				path = path.components(separatedBy: "-Runner.app").dropLast().joined() + "-Runner.app"
			}
			return path.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: "")
        }
        //filesToZip.append(config.xctestrunPath.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: ""))
        log?.message(verboseMsg: "Start zip dependent files: \n\t\t- " + filesToZip.joined(separator: "\n\t\t- "))
        try Run().run(Scripts.zip(workdirectory: self.xctestrun.testRootPath,
                                       zipName: "build.zip",
                                       files: filesToZip))
        let zipPath = "\(self.xctestrun.testRootPath)/build.zip"
        log?.message(verboseMsg: "Zip path: " + zipPath)
        return zipPath
    }
    
    private func getXCResult(path: String) -> XCResult? {
        do {
            let shell = Run()
            let uuid = UUID().uuidString
            let unzipFolderPath = "\(self.config.outputDirectoryPath)/\(uuid)"
            try shell.run("unzip -o -q \"\(path)\" -d \(unzipFolderPath)")
            let files = try shell.run("ls -1 \(unzipFolderPath) | grep -E '.\\.xcresult$'").output
            let xcresultFiles =  files.components(separatedBy: "\n").filter { $0.contains(".xcresult") }
            guard let xcresultFileName = (xcresultFiles.sorted { $0 > $1 }).first else {
                log?.error("*.xcresult files was not found: \(unzipFolderPath)")
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
            log?.error("\(err)")
            return nil
        }
    }
    
    private func checkout(runner: Runner) {
        runner.finished = true
        if (self.runners.filter { $0.finished == false }).count == 0 {
            log?.message(verboseMsg: "All nodes finished")
            let mergedResultsPath = "'\(self.config.outputDirectoryPath)/final/final_result.xcresult'"
            let JUnitReportUrl = URL(fileURLWithPath: "\(self.config.outputDirectoryPath)/final/final_result.xml")
            let JSONReportUrl = URL(fileURLWithPath: "\(self.config.outputDirectoryPath)/final/final_result.json")
            do {
                log?.message(verboseMsg: "Merging results...")
                if let mergeXCResult = try? self.xcresulttool.merge(inputPaths: self.xcresultFiles, outputPath: mergedResultsPath), mergeXCResult.status != 0 {
                    log?.message(verboseMsg: mergeXCResult.output)
                } else {
                    log?.message(verboseMsg: "All results is merged: \(mergedResultsPath)")
                }
                let duration = Date.timeIntervalSinceReferenceDate - self.time
                try JSONReport.generate(tests: self.tests, duration: duration).write(to: JSONReportUrl)
                try JUnit().generate(tests: self.tests).write(to: JUnitReportUrl, atomically: true, encoding: .utf8)
                let reran = self.tests.reran
                let failed = self.tests.failed
                let unexecuted = self.tests.unexecuted
                
				_ = try? ("Total Tests: \(self.tests.count)\n" +
				"Passed: \(self.tests.passed.count) tests\n" +
				"Failed: \(failed.count) tests")
					.write(toFile: "\(self.config.outputDirectoryPath)/final/final_result.txt", atomically: true, encoding: .utf8)
				
				quiet = false
                print()
                log?.message("####################################\n")
                log?.message("Total Tests: \(self.tests.count)")
                log?.message("Passed: \(self.tests.passed.count) tests")
                log?.message("Reran: \(reran.count) tests")
                reran.forEach {
                    log?.warning(before: "\t", "\($0.name) - \($0.launchCounter - 1) times")
                }
                log?.message("Failed: \(failed.count) tests")
                failed.forEach {
                    log?.failed(before: "\t", $0.name)
                }
                log?.message("Unexecuted: \(unexecuted.count) tests")
                unexecuted.forEach {
                    log?.failed(before: "\t", $0.name)
                }
                
                log?.message("Done: in \(String(format: "%.3f", duration)) seconds")
                print()
                log?.message("####################################")
                
                if failed.count == 0 && unexecuted.count == 0 {
                    exit(0)
                }
                exit(1)
            } catch let err {
                log?.error("\(err)")
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
        self.queue.async { [self] in
            log?.message(verboseMsg: "Parse test results from \(runner.name)")
            guard let pathToResults = pathToResults,
                  var xcresult = self.getXCResult(path: pathToResults) else {
                executedTests.forEach {
                    self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
                    log?.failed("\(runner.name): \($0) - Was not executed")
                }
                return
            }
            
            do {
                let testsMetadata = try xcresult.testsMetadata()
                    .reduce(into: [String: ActionTestMetadata]()) { dictionary, value in
                        dictionary[value.identifier] = value
                }
                try executedTests.forEach {
					let executedTest = $0.suffix(2) != "()" ? "\($0)()" : $0
                    guard let testMetaData = testsMetadata[executedTest] else {
                        self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
                        log?.failed("\(runner.name): \($0) - Was not executed")
                        return
                    }
                    if testMetaData.testStatus == "Success" {
                        self.tests.update(test: $0, state: .pass, duration: testMetaData.duration ?? 0.0)
                        log?.success("\(runner.name): \($0) " +
                        "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
                    } else {
                        let summary: ActionTestSummary = try xcresult.modelFrom(reference: testMetaData.summaryRef!)
                        var message = summary.failureSummaries.compactMap { $0.message }.joined(separator: " ")
                        if message.isEmpty {
                            message = summary.allChildActivitySummaries()
                                .filter{$0.activityType == "com.apple.dt.xctest.activity-type.testAssertionFailure"}
                                .map{ $0.title }
                                .joined(separator: "\n")
                        }
                        self.tests.update(test: $0,
                                          state: .failed,
                                          duration: testMetaData.duration ?? 0.0,
                                          message: message)
                        log?.failed("\(runner.name): \($0) " +
                        "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
                        log?.message(verboseMsg: "\(runner.name): \($0) - \(testMetaData.testStatus):\n\t\t- \(message)")
                    }
                }
            } catch let err {
                log?.error("\(err)")
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
}
