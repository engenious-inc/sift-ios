import Foundation

struct SSHCommunication: Communication {
    private let ssh: SSHExecutor
    private let config: Config.NodeConfig
    private let remoteWorkPath: String
    private let log: Logging?

    var nodeName: String { config.name }

    init(config: Config.NodeConfig, remoteWorkPath: String, sshFactory: (Config.NodeConfig) -> SSHExecutor, log: Logging?) {
        self.config = config
        self.remoteWorkPath = remoteWorkPath
        self.ssh = sshFactory(config)
        self.log = log
    }

    func connect() async throws {
        log?.message(verboseMsg: "Connecting to \(nodeName) (\(config.host):\(config.port))...")
        try await ssh.connect(
            username: config.username,
            password: config.password,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            passphrase: config.passphrase
        )
        log?.message(verboseMsg: "\(nodeName): connection established")
    }

    func getBuildOnRunner(buildPath: String) async throws {
        log?.message(verboseMsg: "Uploading build to \(nodeName)...")
        let remoteZipPath = "\(remoteWorkPath)/build.zip"
        let mkdir = try await ssh.run("mkdir -p \(remoteWorkPath.shellQuoted)")
        guard mkdir.status == 0 else {
            throw NSError(domain: "\(nodeName): cannot create remote work directory \(remoteWorkPath): \(mkdir.output)", code: 1)
        }
        try await ssh.uploadFile(localPath: buildPath, remotePath: remoteZipPath)
        let unzip = try await ssh.run("unzip -o -q \(remoteZipPath.shellQuoted) -d \(remoteWorkPath.shellQuoted)")
        guard unzip.status == 0 else {
            throw NSError(domain: "\(nodeName): unzip of uploaded build failed: \(unzip.output)", code: 1)
        }
        _ = try? await ssh.run("rm \(remoteZipPath.shellQuoted)")
        log?.message(verboseMsg: "\(nodeName): build unpacked at \(remoteWorkPath)")
    }

    func saveOnRunner(xctestrun: XCTestRun) async throws -> String {
        let data = try xctestrun.data()
        let xctestrunPath = "\(remoteWorkPath)/\(xctestrun.xctestrunFileName)"
        log?.message(verboseMsg: "Uploading .xctestrun to \(nodeName): \(xctestrun.xctestrunFileName)")
        try await ssh.uploadFile(data: data, remotePath: xctestrunPath)
        return xctestrunPath
    }

    func executeOnRunner(command: String) async throws -> (status: Int32, output: String) {
        try await ssh.run(command)
    }

    /// Removes exactly this run's remote directory — nothing else.
    func cleanup() async {
        _ = try? await ssh.run("rm -rf \(remoteWorkPath.shellQuoted)")
    }
}
