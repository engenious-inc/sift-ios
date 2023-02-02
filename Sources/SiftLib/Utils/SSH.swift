import Foundation
import Shout

final class SSH: SSHExecutor, ShellExecutor {
    private let ssh: Shout.SSH
    private let host: String
    private let port: Int32
	private let arch: Config.NodeConfig.Arch?
    
    init(host: String, port: Int32 = 22, arch: Config.NodeConfig.Arch? = nil) throws {
        self.ssh = try Shout.SSH(host: host, port: port)
        self.host = host
        self.port = port
		self.arch = arch
    }
    
    func authenticate(username: String, password: String?, privateKey: String?, publicKey: String?, passphrase: String?) throws {
        if let password = password {
            try ssh.authenticate(username: username, password: password)
        } else if let privateKey = privateKey {
            try ssh.authenticate(username: username, privateKey: privateKey, publicKey: publicKey, passphrase: passphrase)
        } else {
            try ssh.authenticateByAgent(username: username)
        }
    }
    
    @discardableResult
    func uploadFile(localPath: String, remotePath: String) throws -> Self {
        try ssh.openSftp().upload(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func uploadFile(data: Data, remotePath: String) throws -> Self {
        try ssh.openSftp().upload(data: data, remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func uploadFile(string: String, remotePath: String) throws -> Self {
        try ssh.openSftp().upload(string: string, remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func downloadFile(remotePath: String, localPath: String) throws -> Self {
        try ssh.openSftp().download(remotePath: remotePath, localURL: URL(fileURLWithPath: localPath))
        return self
    }
    
    @discardableResult
    func run(_ command: String) throws -> (status: Int32, output: String) {
		let command = arch != nil ? "arch -\(arch!.rawValue) /bin/sh -c \"\(command)\"" : command
		return try self.ssh.capture(command)
    }
    
    @discardableResult
    func runInBackground(_ command: String, temporaryDirectory: String? = nil) throws -> String {
        let uuid = UUID().uuidString
        let temporaryDirectory = temporaryDirectory ?? FileManager().temporaryDirectory.absoluteString
        let exitStatusPath = "\(temporaryDirectory)/ExitStatus_\(uuid)"
        let command = command + "; " + "echo \\$? > \(exitStatusPath)"
        try self.ssh.executeSilent("nohup /bin/sh -c \"\(command)\" &")
        return exitStatusPath
    }
}
