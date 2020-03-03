import Foundation

class SSHCommunication<SSH: SSHExecutor>: Communication {
    private let ssh: SSHExecutor
    private let temporaryBuildZipName = "build.zip"
    private let runnerDeploymentPath: String
    private let masterDeploymentPath: String
    
    init(host: String,
         port: Int32 = 22,
         username: String,
         password: String,
         runnerDeploymentPath: String,
         masterDeploymentPath: String) throws {
        self.runnerDeploymentPath = runnerDeploymentPath
        self.masterDeploymentPath = masterDeploymentPath
        self.ssh = try SSH(host: host, port: port)
        try self.ssh.authenticate(username: username, password: password)
    }
    
    func getBuildOnRunner(buildPath: String) throws {
        let buildPathOnNode = "\(runnerDeploymentPath)/\(temporaryBuildZipName)"
        _ = try? self.ssh.run("mkdir \(runnerDeploymentPath)")
        _ = try? self.ssh.run("rm -r \(runnerDeploymentPath)/*")
        try self.ssh.uploadFile(localPath: buildPath, remotePath: buildPathOnNode)
        try self.ssh.run("unzip -o -q \(buildPathOnNode) -d \(runnerDeploymentPath)")
    }
    
    func sendResultsToMaster(UDID: String) throws -> String? {
        let resultsFolderPath = "\(runnerDeploymentPath)/\(UDID)/Logs/Test"
        let (_, filesString) = try self.ssh.run("ls -1 \(resultsFolderPath) | grep -E '.\\.xcresult$'")
        let xcresultFiles =  filesString.components(separatedBy: "\n")
        guard let xcresult = (xcresultFiles.filter { $0.contains(".xcresult") }.sorted { $0 > $1 }).first else {
            error("*.xcresult files not found in \(resultsFolderPath): \n \(filesString)")
            return nil
        }
        
        let masterPath = "\(masterDeploymentPath)/\(UDID).zip"
        try self.ssh.run("cd '\(resultsFolderPath)'\n" + "zip -r -X './\(UDID).zip' './\(xcresult)'")
        try self.ssh.downloadFile(remotePath: "\(resultsFolderPath)/\(UDID).zip", localPath: "\(masterPath)")
        _ = try? self.ssh.run("rm -r \(resultsFolderPath)")
        return masterPath
    }
    
    func saveOnRunner(xctestrun: XCTestRun) throws -> String {
        let data = try xctestrun.data()
        guard let xctestrunFileName = xctestrun.path.components(separatedBy: "/").last else {
            throw NSError(domain: "xctestrun source file was not found - \(xctestrun.path)", code: 1, userInfo: nil)
        }
        let xctestrunPath = "\(runnerDeploymentPath)/\(xctestrunFileName)"
        try self.ssh.uploadFile(data: data, remotePath: xctestrunPath)
        return xctestrunPath
    }
}
