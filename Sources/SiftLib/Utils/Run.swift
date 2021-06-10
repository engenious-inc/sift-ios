import Foundation
import Shell

public struct Run: ShellExecutor {
    
    let shell = Shell()
	public let arch: Config.NodeConfig.Arch?
	
	public init(arch: Config.NodeConfig.Arch? = nil) {
		self.arch = arch
	}
    
    @discardableResult
    public func run(_ command: String) throws -> (status: Int32, output: String)  {
		let execute = self.arch != nil ? ["arch -\(self.arch!.rawValue)", "/bin/sh", "-c", command] : ["/bin/sh", "-c", command]
        let output = try shell.capture(execute).get()
        let statusString = (try? shell.capture(["/bin/sh", "-c", "echo $?"]).get()) ?? "-1"
        let statusInt = Int32(statusString.filter { !$0.isNewline && !$0.isWhitespace }) ?? -1
        return (statusInt, output)
    }
}
