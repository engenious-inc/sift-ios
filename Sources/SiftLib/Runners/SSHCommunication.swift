import Foundation

struct SSHCommunication<SSH: SSHExecutor>: Communication {
    private let ssh: SSHExecutor!
    private let temporaryBuildZipName = "build.zip"
    private let runnerDeploymentPath: String
    private let masterDeploymentPath: String
    private let nodeName: String
    private let log: Logging?
    
	init(
		host: String,
		port: Int32 = 22,
		username: String,
		password: String?,
		privateKey: String?,
		publicKey: String?,
		passphrase: String?,
		runnerDeploymentPath: String,
		masterDeploymentPath: String,
		nodeName: String,
		arch: Config.NodeConfig.Arch?,
		log: Logging?
	) throws {
		self.log = log
		self.runnerDeploymentPath = runnerDeploymentPath
		self.masterDeploymentPath = masterDeploymentPath
		self.nodeName = nodeName
		log?.message(verboseMsg: "Connecting to: \(nodeName) (\(host):\(port))...")
		self.ssh = try SSH(host: host, port: port, arch: arch)
		try self.ssh.authenticate(
			username: username,
			password: password,
			privateKey: privateKey,
			publicKey: publicKey,
			passphrase: passphrase
		)
		log?.message(verboseMsg: "\(nodeName): Connection successfully established")
	}
    
    func getBuildOnRunner(buildPath: String) throws {
        log?.message(verboseMsg: "Uploading build to \(self.nodeName)...")
        let buildPathOnNode = "\(self.runnerDeploymentPath)/\(self.temporaryBuildZipName)"
        _ = try? self.ssh.run("mkdir \(self.runnerDeploymentPath)")
        _ = try? self.ssh.run("rm -r \(self.runnerDeploymentPath)/*")
        try self.ssh.uploadFile(localPath: buildPath, remotePath: buildPathOnNode)
        try self.ssh.run("unzip -o -q \(buildPathOnNode) -d \(self.runnerDeploymentPath)")
        log?.message(verboseMsg: "\(self.nodeName): Build successfully uploaded to: \(self.runnerDeploymentPath)")
    }
    
    func saveOnRunner(xctestrun: XCTestRun) throws -> String {
        let data = try xctestrun.data()
        let xctestrunPath = "\(self.runnerDeploymentPath)/\(xctestrun.xctestrunFileName)"
        log?.message(verboseMsg: "Uploading parsed .xctestrun file to \(self.nodeName): \(xctestrun.xctestrunFileName)")
        try self.ssh.uploadFile(data: data, remotePath: xctestrunPath)
        log?.message(verboseMsg: "\(self.nodeName) .xctestrun file uploaded successfully: \(xctestrunPath)")
        return xctestrunPath
    }
    
    func executeOnRunner(command: String) throws -> (status: Int32, output: String) {
        return try self.ssh.run(command)
    }
}
