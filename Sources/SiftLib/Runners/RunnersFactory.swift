import Foundation

class RunnersFactory {
    static func create(config: Config, delegate: RunnerDelegate) -> [Runner] {
        return config.nodes.compactMap {
            do {
                return try Node(config: $0,
                                outputDirectoryPath: config.outputDirectoryPath,
                                testsExecutionTimeout: config.testsExecutionTimeout,
                                setUpScriptPath: config.setUpScriptPath,
                                tearDownScriptPath: config.tearDownScriptPath,
                                delegate: delegate)
            } catch let err {
                error("Cant initialize Runner: \($0.name)\n\(err)")
                return nil
            }
        }
    }
}
