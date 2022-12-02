import Foundation

public class Controller {
    private let config: Config
    private let xctestrun: XCTestRun
    private var runners: [Runner] = []
    private let time = Date.timeIntervalSinceReferenceDate
    private var zipBuildPath: String? = nil
    private var xcresultFiles: Atomic<[String]>
    private var xcresulttool: XCResultTool!
    public var tests: TestCases
    public private(set) var bundleTests: [String]
    private let log: Logging?
	private var tasks: [Task<(), Never>] = []
	private let isTestProcessingDisabled: Bool

	public init(config: Config, tests: [String]? = nil, isTestProcessingDisabled: Bool = false, log: Logging?) throws {
		self.isTestProcessingDisabled = isTestProcessingDisabled
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
        self.xcresultFiles = Atomic(value: [])
    }
	
    @discardableResult
	public func start() -> Task<(), Never> {
        Task {
            do {
                let shell = Run()
                self.xcresulttool = XCResultTool()
                log?.message("Total tests for execution: \(await self.tests.count)")
                log?.message(verboseMsg: "Create/Clean: \(self.config.outputDirectoryPath)")
                _ = try? shell.run("mkdir \(self.config.outputDirectoryPath)")
                _ = try? shell.run("rm -r \(self.config.outputDirectoryPath)/*")
                self.zipBuildPath = try self.zipBuild()
                self.runners = RunnersFactory.create(config: self.config, delegate: self, log: log)
                await self.runners.concurrentForEach {
                    await $0.start()
                }
				await self.checkout()
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
    
    private func getXCResult(path: String) async -> XCResult? {
        do {
            let shell = Run()
            let uuid = UUID().uuidString
            let unzipFolderPath = "\(self.config.outputDirectoryPath)/\(uuid)"
            
            try shell.run("unzip -o -q \"\(path)\" -d \(unzipFolderPath)")
            var files = ""
            for limit in 1...3 where files.isEmpty {
                if limit > 1 { sleep(1) }
                files = try shell.run("ls -1 \(unzipFolderPath) | grep -E '.\\.xcresult$'").output
            }
            let xcresultFiles =  files.components(separatedBy: "\n").filter { $0.contains(".xcresult") }
            guard let xcresultFileName = (xcresultFiles.sorted { $0 > $1 }).first else {
                log?.error("*.xcresult files was not found: \(unzipFolderPath)")
                return nil
            }
            
            let xcresultAbsolutePath = "\(unzipFolderPath)/\(xcresultFileName)"
            _ = try? shell.run("mkdir \(self.config.outputDirectoryPath)/final")
            try shell.run("cp -R '\(xcresultAbsolutePath)' " +
                               "'\(self.config.outputDirectoryPath)/final/\(uuid).xcresult'")
            
            await self.xcresultFiles.append(value: "\(self.config.outputDirectoryPath)/final/\(uuid).xcresult")
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
    
	@MainActor private func checkout() async {
		for task in self.tasks {
			await task.value
		}
		log?.message(verboseMsg: "All nodes finished")
		let mergedResultsPath = "'\(self.config.outputDirectoryPath)/final/final_result.xcresult'"
		let JUnitReportUrl = URL(fileURLWithPath: "\(self.config.outputDirectoryPath)/final/final_result.xml")
		let JSONReportUrl = URL(fileURLWithPath: "\(self.config.outputDirectoryPath)/final/final_result.json")
		do {
			log?.message(verboseMsg: "Merging results...")
			var xcresultFiles = await self.xcresultFiles.getValue()
			if xcresultFiles.isEmpty {
				xcresultFiles = try unzipTestsResults()
			}
			if let mergeXCResult = try? self.xcresulttool.merge(inputPaths: xcresultFiles, outputPath: mergedResultsPath), mergeXCResult.status != 0 {
				log?.message(verboseMsg: mergeXCResult.output)
			} else {
				log?.message(verboseMsg: "All results is merged: \(mergedResultsPath)")
			}
			
			guard self.isTestProcessingDisabled == false else {
				exit(0)
			}
			
			let duration = Date.timeIntervalSinceReferenceDate - self.time
			try await JSONReport.generate(tests: self.tests, duration: duration).write(to: JSONReportUrl)
			try await JUnit().generate(tests: self.tests).write(to: JUnitReportUrl, atomically: true, encoding: .utf8)
			let reran = await self.tests.reran
			let failed = await self.tests.failed
			let unexecuted = await self.tests.unexecuted
			
			_ = try? ("Total Tests: \(await self.tests.count)\n" +
					  "Passed: \(await self.tests.passed.count) tests\n" +
			"Failed: \(failed.count) tests")
				.write(toFile: "\(self.config.outputDirectoryPath)/final/final_result.txt", atomically: true, encoding: .utf8)
			
			quiet = false
			print()
			log?.message("####################################\n")
			log?.message("Total Tests: \(await self.tests.count)")
			log?.message("Passed: \(await self.tests.passed.count) tests")
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
	
	private func unzipTestsResults() throws -> [String] {
		let shell = Run()
		let files = try shell.run("ls -1 '\(self.config.outputDirectoryPath)' | grep -E '.\\.zip$'").output
			.components(separatedBy: "\n")
			.compactMap {
				return $0.isEmpty ? nil : "\(self.config.outputDirectoryPath)/\($0)"
			}
		try shell.run("mkdir \(self.config.outputDirectoryPath)/final")
		return files.flatMap { zipFile in
			let uuid = UUID().uuidString
			let unzipFolderPath = "\(self.config.outputDirectoryPath)/\(uuid)"
			_ = try? shell.run("unzip -o -q \"\(zipFile)\" -d \(unzipFolderPath)")
			_ = try? shell.run("rm -r '\(zipFile)'")
			let xcresultFilesString = (try? shell.run("ls -1 \(unzipFolderPath) | grep -E '.\\.xcresult$'").output) ?? ""
			let xcresultFiles =  xcresultFilesString.components(separatedBy: "\n").filter { $0.contains(".xcresult") }
			
			let results = xcresultFiles.map { xcresultFileName in
				let xcresultAbsoluteTempPath = "\(unzipFolderPath)/\(xcresultFileName)"
				let xcresultAbsoluteFinalPath = "\(self.config.outputDirectoryPath)/final/\(uuid).xcresult"
				_ = try? shell.run("cp -R '\(xcresultAbsoluteTempPath)' " +
							  "'\(xcresultAbsoluteFinalPath)'")
				return xcresultAbsoluteFinalPath
			}
			
			_ = try? shell.run("rm -r '\(unzipFolderPath)'")
			
			return results
		}
	}
}

//MARK: - TestsRunnerDelegate implementation
extension Controller: RunnerDelegate {    
    public func handleTestsResults(runner: Runner, executedTests: [String], pathToResults: String?) {
		guard isTestProcessingDisabled == false else {
			return
		}
		let task = Task {
			log?.message(verboseMsg: "Parse test results from \(runner.name)")
			guard let pathToResults = pathToResults,
				  var xcresult = await self.getXCResult(path: pathToResults) else {
				log?.warning("Can't parse file:" + (pathToResults ?? "NO PATH TO .xcresultfile"))
				await executedTests.asyncForEach {
					await self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
					self.log?.failed("\(runner.name): \($0) - Was not executed")
				}
				return
			}

			log?.message(verboseMsg: "\(runner.name) Parsing: \(xcresult.path)")
			var testsMetadataBuff = try? xcresult.testsMetadata()
			for _ in 1...3 where testsMetadataBuff?.isEmpty ?? true {
				sleep(1)
				testsMetadataBuff = try? xcresult.testsMetadata()
			}
			
			guard let testsMetadataBuff = testsMetadataBuff else {
				log?.error("handleTestsResults: Can't get Tests Metadata")
				await executedTests.asyncForEach {
					await self.tests.update(test: $0, state: .unexecuted, duration: 0.0, message: "Was not executed")
					self.log?.failed("\(runner.name): \($0) - Was not executed")
				}
				return
			}
			
			let testsMetadata = testsMetadataBuff.reduce(into: [String: ActionTestMetadata]()) { dictionary, value in
					dictionary[value.identifier] = value
				}
			for executedTest in executedTests {
				let executedTest = executedTest.suffix(2) != "()" ? "\(executedTest)()" : executedTest
				guard let testMetaData = testsMetadata[executedTest] else {
					await self.tests.update(test: executedTest, state: .unexecuted, duration: 0.0, message: "Was not executed")
					self.log?.failed("\(runner.name): \(executedTest) - Was not executed")
					continue
				}
				if testMetaData.testStatus == "Success" {
					await self.tests.update(test: executedTest, state: .pass, duration: testMetaData.duration ?? 0.0)
					self.log?.success("\(runner.name): \(executedTest) " +
									  "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
				} else {
					guard let summaryRef = testMetaData.summaryRef, let summary: ActionTestSummary = try? xcresult.modelFrom(reference: summaryRef) else {
						log?.error("handleTestsResults: Can't make a model from \(testMetaData.summaryRef?.id ?? "Unknown")")
						return
					}
					var message = summary.failureSummaries.compactMap { $0.message }.joined(separator: " ")
					if message.isEmpty {
						message = summary.allChildActivitySummaries()
							.filter{$0.activityType == "com.apple.dt.xctest.activity-type.testAssertionFailure"}
							.map{ $0.title }
							.joined(separator: "\n")
					}
					await self.tests.update(test: executedTest,
											state: .failed,
											duration: testMetaData.duration ?? 0.0,
											message: message)
					self.log?.failed("\(runner.name): \(executedTest) " +
									 "- \(testMetaData.testStatus): \(String(format: "%.3f", testMetaData.duration ?? 0)) sec.")
					self.log?.message(verboseMsg: "\(runner.name): \(executedTest) - \(testMetaData.testStatus):\n\t\t- \(message)")
				}
			}
        }
		
		self.tasks.append(task)
    }
    
    public func XCTestRun() throws -> XCTestRun {
        return try XCTestRunFactory.create(path: config.xctestrunPath, log: nil)
    }
    
    public func buildPath() async -> String {
        return self.zipBuildPath!
    }
    
    public func getTests() async -> [String] {
        var testsForExecution = await self.tests.next(amount: self.config.testsBucket)
        if testsForExecution.isEmpty, let testForRerun = await self.tests.nextForRerun() {
            testsForExecution.append(testForRerun)
        }
        return testsForExecution
    }
}
