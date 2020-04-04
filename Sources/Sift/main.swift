import Foundation
import SiftLib
import Guaka

let path = Flag(shortName: "c",
                longName: "config",
                type: String.self,
                description: "Path to the JSON config file.",
                required: true,
                inheritable: false)

let onlyTesting = Flag(shortName: "o",
                longName: "only-testing",
                type: [String].self,
                description: "Tests for execution.",
                required: false,
                inheritable: false)

let testsPath = Flag(shortName: "t",
                       longName: "tests-path",
                       type: String.self,
                       description: "Path to tests for execution.",
                       required: false,
                       inheritable: false)

let rootCommand = Command(usage: "Sift",
                          shortMessage: "",
                          flags: [],
                          example: nil,
                          parent: nil,
                          aliases: [])

let _ = Command(usage: "run",
                shortMessage: "Execute tests",
                flags: [path, onlyTesting, testsPath],
                example: nil,
                parent: rootCommand,
                aliases: []) { flags, args in
                
    guard let path = flags.get(name: "config", type: String.self) else {
        fatalError("No path to the config file")
    }

    var tests = flags.get(name: "only-testing", type: [String].self)
    if let testsPath = flags.get(name: "tests-path", type: String.self) {
        do {
            tests = try String(contentsOfFile: testsPath)
                        .components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
        } catch let err {
            error("\(err)")
            exit(1)
        }
    }

    do {
        let config = try Config(path: path)
        let testsProcessor = try Controller(config: config, tests: tests)
        testsProcessor.start()
        
        dispatchMain()
    } catch let err {
        error("\(err)")
        exit(1)
    }
}

let _ = Command(usage: "list",
                shortMessage: "Print all tests in bundles",
                flags: [path],
                example: nil,
                parent: rootCommand,
                aliases: ["list-tests"]) { flags, args in
    guard let path = flags.get(name: "config", type: String.self) else {
        fatalError("No path to the config file")
    }
    
    do {
        quiet = true
        let config = try Config.init(path: path)
        let testsProcessor = try Controller(config: config)
        testsProcessor.testsNames.sorted().forEach {
            print($0)
        }
    } catch let err {
        error("\(err)")
        exit(1)
    }
}

rootCommand.execute()
