@preconcurrency import ArgumentParser
import Foundation
import SiftLib

setbuf(__stdoutp, nil)

struct Sift: ParsableCommand, Sendable {
	static let configuration = CommandConfiguration(
        abstract: "A utility for parallel XCTest execution.",
        subcommands: [Run.self, List.self],
        defaultSubcommand: Run.self)
}

extension Sift {

	struct Run: ParsableCommand, Sendable {
		static let configuration = CommandConfiguration(abstract: "Test execution command.")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        @Option(name: [.customShort("p"), .customLong("tests-path")], help: "Path to a text file with list of tests for execution.")
        var testsPath: String?

        @Option(name: [.short, .customLong("only-testing")], help: "Test for execution.")
        var onlyTesting: [String] = []

        @Flag(name: [.short, .customLong("verbose")], help: "Verbose mode.")
        var verboseMode: Bool = false

		@Option(name: [.customShort("t"), .customLong("timeout")], help: "Timeout in seconds.")
		var timeout: Int?
		
		@Flag(name: [.customLong("disable-tests-results-processing")], help: "Experimental! - Disable processing of test results in real time - might reduce execution time.")
		var isTestProcessingDisabled: Bool = false

		mutating func run() {
            let onlyTesting = self.onlyTesting
            let testsPath = self.testsPath
            let path = self.path
            let isTestProcessingDisabled = self.isTestProcessingDisabled
            
			var log = Log()
			log.verbose = verboseMode

            let mainTask = Task {
                do {
                    var tests: [String] = onlyTesting

                    if let testsPath = testsPath {
                        tests = try String(contentsOfFile: testsPath)
                            .components(separatedBy: "\n")
                            .filter { !$0.isEmpty }
                    }

                    let config = try Config(path: path)
                    let testsController = try await Controller(
                        config: config,
                        tests: tests,
                        isTestProcessingDisabled: isTestProcessingDisabled,
                        log: log
                    )
                    await testsController.start()
                } catch let error {
                    log.error("\(error)")
                    Sift.exit(withError: error)
                }
            }

            if let timeout = timeout {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                    var log = Log()
                    log.verbose = true
                    log.error("Timeout")
                    mainTask.cancel()
                    Sift.exit()
                }
            }
            RunLoop.main.run()
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print all tests in bundles")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        mutating func run() {
            let path = path
            Task {
                var log = Log()
                log.quiet = true
                do {
                    let config = try Config(path: path)
                    let testsController = try await Controller(config: config, log: log)
                    print(testsController.tests)
                } catch let error {
                    log.error("\(error)")
                    Sift.exit(withError: error)
                }
            }
            RunLoop.main.run()
        }
    }
}

Sift.main()
