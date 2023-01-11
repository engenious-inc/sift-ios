import Foundation

class Device: BaseExecutor {

	override init(type: TestExecutorType,
				  UDID: String,
				  config: Config.NodeConfig,
				  xctestrunPath: String,
				  setUpScriptPath: String?,
				  tearDownScriptPath: String?,
                  runnerDeploymentPath: String,
                  masterDeploymentPath: String,
                  nodeName: String,
                  log: Logging?) throws {

		try super.init(type: type,
					   UDID: UDID,
					   config: config,
					   xctestrunPath: xctestrunPath,
					   setUpScriptPath: setUpScriptPath,
					   tearDownScriptPath: tearDownScriptPath,
                       runnerDeploymentPath: runnerDeploymentPath,
                       masterDeploymentPath: masterDeploymentPath,
                       nodeName: nodeName,
                       log: log)
    }
}

// MARK: - TestExecutor Protocol implementation

extension Device: TestExecutor {

    func ready() -> Bool{
        self.log?.message(verboseMsg: "Device: \"\(self.UDID)\" ready")
        return true
    }
    
    @discardableResult
    func reset() -> Result<TestExecutor, Error> {
        return .success(self)
    }

    func deleteApp(bundleId: String) {}
}
