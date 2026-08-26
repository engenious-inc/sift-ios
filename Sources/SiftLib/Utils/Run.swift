import Foundation

public actor Run: ShellExecutor {
        
    @discardableResult
    public func run(_ command: String) async throws -> (status: Int32, output: String)  {
        let parsedCommand = "/bin/sh"
        let arguments = ["-c", command]
        
        let output = try await CommandLineExecutor.launchProcess(command: parsedCommand, arguments: arguments)
        return (output.terminationStatus, output.standardOut ?? "")
    }
    
    nonisolated public func runInBackground(_ command: String, temporaryDirectory: String? = nil) throws -> String {
        return "" // to do
    }
}
