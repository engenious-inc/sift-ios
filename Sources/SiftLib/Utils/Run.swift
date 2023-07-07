import Foundation

public actor Run: ShellExecutor {
        
    @discardableResult
    nonisolated public func run(_ command: String) throws -> (status: Int32, output: String)  {
        let parsedCommand = "/bin/sh"
        let arguments = ["-c", command]
        
        let output = try CommandLineExecutor.launchProcess(command: parsedCommand, arguments: arguments)
        return (output.terminationStatus, output.standardOut ?? "")
    }
    
    nonisolated public func runInBackground(_ command: String, temporaryDirectory: String? = nil) throws -> String {
        return "" // to do
    }
}
