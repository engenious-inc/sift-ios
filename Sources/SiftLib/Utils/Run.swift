import Foundation

public struct Run: ShellExecutor {
    
	public let arch: Config.NodeConfig.Arch?
	
	public init(arch: Config.NodeConfig.Arch? = nil) {
		self.arch = arch
	}
    
    @discardableResult
    public func run(_ command: String) throws -> (status: Int32, output: String)  {
        var parsedCommand = "/bin/sh"
        var arguments = ["-c", command]
        
        if let arch = self.arch {
            parsedCommand = "arch"
            arguments = ["-\(arch.rawValue)", "/bin/sh", "-c", command]
        }
        
        let output = try CommandLineExecutor.launchProcess(command: parsedCommand, arguments: arguments)
        return (output.terminationStatus, output.standardOut ?? "")
    }
}
