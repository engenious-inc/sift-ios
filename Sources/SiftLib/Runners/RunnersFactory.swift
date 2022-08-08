import Foundation

class RunnersFactory {
    static func create(config: Config, delegate: RunnerDelegate, log: Logging?) -> [Runner] {
        return config.nodes.compactMap {
            do {
                return try Node(config: $0,
                                outputDirectoryPath: config.outputDirectoryPath,
                                testsExecutionTimeout: config.testsExecutionTimeout,
                                setUpScriptPath: config.setUpScriptPath,
                                tearDownScriptPath: config.tearDownScriptPath,
                                delegate: delegate,
                                log: log)
            } catch let err {
                log?.error("Cant initialize Runner: \($0.name)\n\(err)")
                return nil
            }
        }
    }
}
