import Foundation

class Device {

    let type: TestExecutorType
    private var ssh: SSHExecutor!
    private let threadName: String
    private let serialQueue: Queue
    private let xcodePath: String
    private let xctestrunPath: String
    private let derivedDataPath: String
    private var xcodebuild: Xcodebuild!
    private let _UDID: String
    private var _finished: Bool = false
    
    init(UDID: String, config: Config.NodeConfig, xctestrunPath: String) throws {
        self.type = .device
        self._UDID = UDID
        self.xcodePath = config.xcodePath
        self.xctestrunPath = xctestrunPath
        self.derivedDataPath = config.deploymentPath
        self.threadName = UDID
        self.serialQueue = .init(type: .serial, name: self.threadName)
        try self.serialQueue.sync {
            self.ssh = try SSH(host: config.host, port: 22)
            try self.ssh.authenticate(username: config.username, password: config.password)
            self.xcodebuild = Xcodebuild(xcodePath: self.xcodePath, shell: self.ssh)
        }
    }
}

// MARK: - TestExecutor Protocol implementation

extension Device: TestExecutor {
    var UDID: String { self.serialQueue.sync { self._UDID } }
    var finished: Bool { self.serialQueue.sync { self._finished } }
    func ready(completion: @escaping (Bool) -> Void) {
        self.serialQueue.async {
            guard let output = try? self.ssh.run("instruments -s devices").output,
                  output.contains(self.UDID) else {
                error("Device: \(self.UDID) is not connected.")
                completion(false)
                return
            }
            completion(true)
        }
    }
    
    func run(tests: [String],
             timeout: Int,
             completion: ((TestExecutor, Result<[String], TestExecutorError>) -> Void)? = nil) {
        self.serialQueue.async {
            if tests.isEmpty {
                self._finished = true
                completion?(self, .failure(.noTestsForExecution))
                return
            }
            do {
                let result = try self.xcodebuild.execute(tests: tests,
                                                         executorType: self.type,
                                                         UDID: self.UDID,
                                                         xctestrunPath: self.xctestrunPath,
                                                         derivedDataPath: self.derivedDataPath,
                                                         timeout: timeout)
                if result.status == 0 || result.status == 65 {
                    completion?(self, .success(tests))
                    return
                }
                // timeout
                if result.status == 143 {
                    self.reset()
                    sleep(3)
                }
                completion?(self, .failure(.executionError(description: "Device: \(self.UDID) " +
                    "- status \(result.status) " +
                    "\(result.status == 143 ? "- timeout: \(timeout)" : "")",
                    tests: tests)))
            } catch let err {
                completion?(self, .failure(.executionError(description: "Device: \(self.UDID) - \(err)", tests: tests)))
            }
        }
    }
    
    func reset(completion: ((TestExecutor, Error?) -> Void)? = nil) {}
    
    func deleteApp(bundleId: String) {}
}
