import Foundation
import Shout

final class SSH: SSHExecutor, ShellExecutor {
    private let ssh: Shout.SSH
    private let host: String
    private let port: Int32
    private var username: String!
    private var password: String!
    private var sftp: SFTP!
    
    init(host: String, port: Int32 = 22) throws {
        self.ssh = try Shout.SSH(host: host, port: port)
        self.host = host
        self.port = port
    }
    
    func authenticate(username: String, password: String) throws {
        try ssh.authenticate(username: username, password: password)
        self.username = username
        self.password = password
        self.sftp = try ssh.openSftp()
    }
    
    @discardableResult
    func uploadFile(localPath: String, remotePath: String) throws -> Self {
        try self.sftp.upload(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func uploadFile(data: Data, remotePath: String) throws -> Self {
        try self.sftp.upload(data: data, remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func uploadFile(string: String, remotePath: String) throws -> Self {
        try self.sftp.upload(string: string, remotePath: remotePath)
        return self
    }
    
    @discardableResult
    func downloadFile(remotePath: String, localPath: String) throws -> Self {
        try self.sftp.download(remotePath: remotePath, localURL: URL(fileURLWithPath: localPath))
        return self
    }
    
    func run(_ command: String) throws -> (status: Int32, output: String) {
        try self.ssh.capture(command)
    }
}
