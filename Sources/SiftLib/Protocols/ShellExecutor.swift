import Foundation

public protocol ShellExecutor: Sendable {
    @discardableResult
    func run(_ command: String) throws -> (status: Int32, output: String)
    func runInBackground(_ command: String, temporaryDirectory: String?) throws -> String
}
