import ArgumentParser
import Foundation
import SiftLib

setbuf(__stdoutp, nil)

struct Sift: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A utility for parallel XCTest execution.",
        subcommands: [Run.self, List.self],
        defaultSubcommand: Run.self)
    
    struct Configure: ParsableArguments {
        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String
    }
}

extension Sift {
    struct Run: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Test execution command.")

        @OptionGroup()
        var configure: Configure

        @Option(name: [.short, .customLong("tests-path")], help: "Path to a text file with list of tests for execution.")
        var testsPath: String?

        @Option(name: [.short, .customLong("only-testing")], help: "Test for execution.")
        var onlyTesting: [String]

        @Flag(name: [.short, .customLong("verbose")], help: "Verbose mode.")
        var verboseMode: Bool

        mutating func run() {
            verbose = verboseMode
            var tests: [String] = onlyTesting
  
            if let testsPath = testsPath {
                do {
                    tests = try String(contentsOfFile: testsPath)
                                .components(separatedBy: "\n")
                                .filter { !$0.isEmpty }
                } catch let err {
                    Log.error("\(err)")
                    Sift.exit(withError: NSError())
                }
            }

            do {
                let config = try Config(path: configure.path)
                let testsProcessor = try Controller(config: config, tests: tests)
                testsProcessor.start()
                
                dispatchMain()
            } catch let err {
                Log.error("\(err)")
                Sift.exit(withError: NSError())
            }
        }
    }

    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Print all tests in bundles")

        @OptionGroup()
        var configure: Configure

        mutating func run() {
            do {
                quiet = true
                let config = try Config.init(path: configure.path)
                let testsProcessor = try Controller(config: config)
                print(testsProcessor.tests)
            } catch let err {
                Log.error("\(err)")
                Sift.exit(withError: NSError())
            }
        }
    }
}

Sift.main()
