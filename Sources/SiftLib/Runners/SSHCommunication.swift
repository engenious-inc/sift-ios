import Foundation

class SSHCommunication<SSH: SSHExecutor>: Communication {
    private let queue: Queue
    private var ssh: SSHExecutor!
    private let temporaryBuildZipName = "build.zip"
    private let runnerDeploymentPath: String
    private let masterDeploymentPath: String
    private let nodeName: String
    
    init(host: String,
         port: Int32 = 22,
         username: String,
         password: String?,
         privateKey: String?,
         publicKey: String?,
         passphrase: String?,
         runnerDeploymentPath: String,
         masterDeploymentPath: String,
         nodeName: String,
		 arch: Config.NodeConfig.Arch?) throws {
        self.runnerDeploymentPath = runnerDeploymentPath
        self.masterDeploymentPath = masterDeploymentPath
        self.nodeName = nodeName
        self.queue = .init(type: .serial, name: "io.engenious.\(host).\(UUID().uuidString)")
        try self.queue.sync {
            Log.message(verboseMsg: "Connecting to: \(nodeName) (\(host):\(port))...")
            self.ssh = try SSH(host: host, port: port, arch: arch)
            try self.ssh.authenticate(username: username,
                                      password: password,
                                      privateKey: privateKey,
                                      publicKey: publicKey,
                                      passphrase: passphrase)
            Log.message(verboseMsg: "\(nodeName): Connection successfully established")
        }
        
    }
    
    func getBuildOnRunner(buildPath: String) throws {
        try self.queue.sync {
            Log.message(verboseMsg: "Uploading build to \(self.nodeName)...")
            let buildPathOnNode = "\(self.runnerDeploymentPath)/\(self.temporaryBuildZipName)"
            _ = try? self.ssh.run("mkdir \(self.runnerDeploymentPath)")
            _ = try? self.ssh.run("rm -r \(self.runnerDeploymentPath)/*")
            try self.ssh.uploadFile(localPath: buildPath, remotePath: buildPathOnNode)
            try self.ssh.run("unzip -o -q \(buildPathOnNode) -d \(self.runnerDeploymentPath)")
            Log.message(verboseMsg: "\(self.nodeName): Build successfully uploaded to: \(self.runnerDeploymentPath)")
        }
    }
    
    func sendResultsToMaster(UDID: String) throws -> String? {
        try self.queue.sync {
            Log.message(verboseMsg: "\(self.nodeName): Uploading tests result to master...")
            let resultsFolderPath = "\(self.runnerDeploymentPath)/\(UDID)/Logs/Test"
            let (_, filesString) = try self.ssh.run("ls -1 \(resultsFolderPath) | grep -E '.\\.xcresult$'")
            let xcresultFiles =  filesString.components(separatedBy: "\n")
            guard let xcresult = (xcresultFiles.filter { $0.contains(".xcresult") }.sorted { $0 > $1 }).first else {
                Log.error("*.xcresult files not found in \(resultsFolderPath): \n \(filesString)")
                return nil
            }
            Log.message(verboseMsg: "\(self.nodeName): Test results: \(xcresult)")
            let masterPath = "\(self.masterDeploymentPath)/\(UDID).zip"
            try self.ssh.run("cd '\(resultsFolderPath)'\n" + "zip -r -X -q -0 './\(UDID).zip' './\(xcresult)'")
            try self.ssh.downloadFile(remotePath: "\(resultsFolderPath)/\(UDID).zip", localPath: "\(masterPath)")
            _ = try? self.ssh.run("rm -r \(resultsFolderPath)")
            Log.message(verboseMsg: "\(self.nodeName): Successfully uploaded on master: \(masterPath)")
            return masterPath
        }
    }
    
    func saveOnRunner(xctestrun: XCTestRun) throws -> String {
        try self.queue.sync {
            let data = try xctestrun.data()
            let xctestrunPath = "\(self.runnerDeploymentPath)/\(xctestrun.xctestrunFileName)"
            Log.message(verboseMsg: "Uploading parsed .xctestrun file to \(self.nodeName): \(xctestrun.xctestrunFileName)")
            try self.ssh.uploadFile(data: data, remotePath: xctestrunPath)
            Log.message(verboseMsg: "\(self.nodeName) .xctestrun file uploaded successfully: \(xctestrunPath)")
            return xctestrunPath
        }
    }
    
    func executeOnRunner(command: String) throws -> (status: Int32, output: String) {
        try self.queue.sync {
            return try self.ssh.run(command)
        }
    }
}
