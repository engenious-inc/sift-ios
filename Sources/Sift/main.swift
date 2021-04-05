import ArgumentParser
import Foundation
import SiftLib

setbuf(__stdoutp, nil)

struct Sift: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A utility for parallel XCTest execution.",
        subcommands: [Orchestrator.self, Run.self, List.self],
        defaultSubcommand: Run.self)
}

extension Sift {

    struct Orchestrator: ParsableCommand {
        @Option(name: .shortAndLong, help: "Token for Orchestrator Auth.")
        var token: String
        
        @Option(name: [.customShort("p"), .customLong("test-plan")], help: "Test plan for execution.")
        var testPlan: String = "default_ios_plan"
        
        @Option(name: .shortAndLong, help: "API endpoint.")
        var endpoint: String = "https://api.orchestrator.engenious.io"
        
        @Flag(name: [.short, .customLong("verbose")], help: "Verbose mode.")
        var verboseMode: Bool = false

        @Flag(name: [.short, .customLong("init")], help: "Init tests for orchestrator.")
        var initMode: Bool = false

        mutating func run() {
            verbose = verboseMode
            let orchestrator = OrchestratorAPI(endpoint: endpoint, token: token, testPlan: testPlan)

            //Get config for testplan
            guard var config = orchestrator.get(status: .enabled) else {
                Log.error("Error: can't get config for TestPlan: \(testPlan)")
                Sift.exit(withError: NSError(domain: "Error: can't get config for TestPlan: \(testPlan)", code: 1))
            }
            config = config.injectedEnvVariables()
            // extract all tests from bundle
            quiet = true
            var testsFromBundle: [String] = []
            do {
                testsFromBundle = try Controller.bundleTests(xctestrunPath: config.xctestrunPath)
            } catch let error {
                Log.error("\(error)")
                Sift.exit(withError: error)
            }
            quiet = false

            //Send all tests to Orchestrator for update
            guard orchestrator.post(tests: testsFromBundle) else {
                Log.error("Can't post new tests to Orchestrator")
                Sift.exit(withError: NSError(domain: "Can't post new tests to Orchestrator", code: 1))
            }
            if initMode {
                Log.message("Tests posted to orchestrator.")
                Sift.exit()
            }
            //Get tests for execution
            guard let newConfig = orchestrator.get(status: .enabled) else {
                Log.error("Error: can't get config for TestPlan: \(testPlan)")
                Sift.exit(withError: NSError(domain: "Error: can't get config for TestPlan: \(testPlan)", code: 1))
            }

            do {
                let testsController = try Controller(config: newConfig, orchestrator: orchestrator)
                testsController.start()
                dispatchMain()
            } catch let error {
                Log.error("\(error)")
                Sift.exit(withError: error)
            }
        }
    }

    struct Run: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Test execution command.")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        @Option(name: [.short, .customLong("tests-path")], help: "Path to a text file with list of tests for execution.")
        var testsPath: String?

        @Option(name: [.short, .customLong("only-testing")], help: "Test for execution.")
        var onlyTesting: [String] = []

        @Flag(name: [.short, .customLong("verbose")], help: "Verbose mode.")
        var verboseMode: Bool = false

        mutating func run() {
            verbose = verboseMode
            var tests: [String] = onlyTesting
  
            if let testsPath = testsPath {
                do {
                    tests = try String(contentsOfFile: testsPath)
                                .components(separatedBy: "\n")
                                .filter { !$0.isEmpty }
                } catch let error {
                    Log.error("\(error)")
                    Sift.exit(withError: error)
                }
            }

            do {
                let config = try Config(path: path)
                let testsController = try Controller(config: config, tests: tests)
                testsController.start()
                dispatchMain()
            } catch let error {
                Log.error("\(error)")
                Sift.exit(withError: error)
            }
        }
    }

    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Print all tests in bundles")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        mutating func run() {
            do {
                quiet = true
                let config = try Config(path: path)
                let tests = try Controller.bundleTests(xctestrunPath: config.xctestrunPath)
                print(tests)
            } catch let error {
                Log.error("\(error)")
                Sift.exit(withError: error)
            }
        }
    }
}

Sift.main()
