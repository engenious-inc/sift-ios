import Foundation

public protocol SSHExecutor: ShellExecutor {
    init(host: String, port: Int32, arch: Config.NodeConfig.Arch?) throws
    func authenticate(username: String, password: String?, privateKey: String?, publicKey: String?, passphrase: String?) throws
    @discardableResult
    func uploadFile(localPath: String, remotePath: String) throws -> Self
    @discardableResult
    func uploadFile(data: Data, remotePath: String) throws -> Self
    @discardableResult
    func uploadFile(string: String, remotePath: String) throws -> Self
    @discardableResult
    func downloadFile(remotePath: String, localPath: String) throws -> Self
}
