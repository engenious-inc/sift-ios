import Foundation

public actor Run: ShellExecutor {
    
	public let arch: Config.NodeConfig.Arch?
    private let timeout: Double
	
	public init(arch: Config.NodeConfig.Arch? = nil, timeout: Double = 180) {
		self.arch = arch
        self.timeout = timeout
	}
    
    @discardableResult
    nonisolated public func run(_ command: String) throws -> (status: Int32, output: String)  {
        var parsedCommand = "/bin/sh"
        var arguments = ["-c", command]
        
        if let arch = self.arch {
            parsedCommand = "arch"
            arguments = ["-\(arch.rawValue)", "/bin/sh", "-c", command]
        }
        
        let output = try CommandLineExecutor.launchProcess(command: parsedCommand, arguments: arguments, timeout: timeout)
        return (output.terminationStatus, output.standardOut ?? "")
    }
}
