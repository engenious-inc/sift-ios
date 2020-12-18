import Foundation
import Shell

public struct Run: ShellExecutor {
    
    let shell = Shell()
    
    public init() {}
    
    @discardableResult
    public func run(_ command: String) throws -> (status: Int32, output: String)  {
        let output = try shell.capture(["/bin/sh", "-c", command]).get()
        let statusString = (try? shell.capture(["/bin/sh", "-c", "echo $?"]).get()) ?? "-1"
        let statusInt = Int32(statusString.filter { !$0.isNewline && !$0.isWhitespace }) ?? -1
        return (statusInt, output)
    }
}
