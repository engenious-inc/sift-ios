import Foundation

class RunnersFactory {
    static func create(config: Config, delegate: RunnerDelegate, log: Logging?) -> [Runner] {
        return config.nodes.compactMap {
            do {
				return try Node(
					config: $0,
					outputDirectoryPath: config.outputDirectoryPath,
					testsExecutionTimeout: config.testsExecutionTimeout,
					setUpScriptPath: config.setUpScriptPath,
					tearDownScriptPath: config.tearDownScriptPath,
					onlyTestConfiguration: config.onlyTestConfiguration,
					skipTestConfiguration: config.skipTestConfiguration,
					delegate: delegate,
					log: log
				)
            } catch {
                log?.error("Cant initialize Runner: \($0.name)\n\(error)")
                return nil
            }
        }
    }
}
