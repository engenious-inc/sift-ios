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

    public init(config: Config, tests: [String]? = nil) throws {
        self.config = config
        let xctestrun = try XCTestRunFactory.init(path: config.xctestrunPath)
		self.xctestrun = xctestrun
        self.bundleTests = self.xctestrun.testBundleExecPaths.flatMap { bundle -> [String] in
            do {
				let moduleName = bundle.path.components(separatedBy: "/").last ?? bundle.target
				let listOfTests: [String] = try TestsDump().dump(path: bundle.path, moduleName: moduleName)
                Log.message("\(bundle.target): \(listOfTests.count) tests")
                return listOfTests
            } catch let err {
                Log.error("\(err)")
                return []
            }
		}

		if !xctestrun.onlyTestIdentifiers.isEmpty {
			// remove tests which not included in xctestrun.onlyTestIdentifiers
			self.bundleTests.removeAll {
				var bundleTestComponents = $0.components(separatedBy: "/")
				let moduleName = bundleTestComponents.removeFirst()
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
			// remove tests which included in xctestrun.skipTestIdentifiers
			self.bundleTests.removeAll {
				var bundleTestComponents = $0.components(separatedBy: "/")
				let moduleName = bundleTestComponents.removeFirst()
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
        let filesToZip: [String] = self.xctestrun.dependentProductPaths.compactMap { (path) -> String? in
			var path = path
			if path.contains("-Runner.app") {
				path = path.components(separatedBy: "-Runner.app").dropLast().joined() + "-Runner.app"
			}
			return path.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: "")
        }
        //filesToZip.append(config.xctestrunPath.replacingOccurrences(of: self.xctestrun.testRootPath + "/", with: ""))
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
                
				_ = try? ("Total Tests: \(self.tests.count)\n" +
				"Passed: \(self.tests.passed.count) tests\n" +
				"Failed: \(failed.count) tests")
					.write(toFile: "\(self.config.outputDirectoryPath)/final/final_result.txt", atomically: true, encoding: .utf8)
				
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
					let executedTest = $0.suffix(2) != "()" ? "\($0)()" : $0
                    guard let testMetaData = testsMetadata[executedTest] else {
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
                        Log.failed("\(runner.name): \($0) " +
                        "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
                        Log.message(verboseMsg: "\(runner.name): \($0) - \(testMetaData.testStatus):\n\t\t- \(message)")
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
}
