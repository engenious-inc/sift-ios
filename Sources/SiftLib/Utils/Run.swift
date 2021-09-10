import Foundation

public struct Run: ShellExecutor {
    
	public let arch: Config.NodeConfig.Arch?
    private let timeout: Double
	
	public init(arch: Config.NodeConfig.Arch? = nil, timeout: Double = 120) {
		self.arch = arch
        self.timeout = timeout
	}
    
    @discardableResult
    public func run(_ command: String) throws -> (status: Int32, output: String)  {
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
