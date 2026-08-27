import Foundation

public struct Run: ShellExecutor {

    public init() {}

    /// Runs a shell command line via /bin/sh. Returns status + stdout; never throws on nonzero status.
    @discardableResult
    public func run(_ command: String) async throws -> (status: Int32, output: String) {
        let result = try await CommandLineExecutor.launch(executable: "/bin/sh", arguments: ["-c", command])
        return (result.status, result.stdout)
    }

    /// Runs an executable directly (no shell). Throws `CommandError` on nonzero exit status.
    @discardableResult
    public func runChecked(_ executable: String, _ arguments: [String], currentDirectory: String? = nil) async throws -> CommandResult {
        let result = try await CommandLineExecutor.launch(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        guard result.status == 0 else {
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr,
                stdout: result.stdout
            )
        }
        return result
    }

    /// Runs an executable directly (no shell). Returns the result without status checking.
    @discardableResult
    public func runUnchecked(_ executable: String, _ arguments: [String], currentDirectory: String? = nil) async throws -> CommandResult {
        try await CommandLineExecutor.launch(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
    }
}
