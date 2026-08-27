import Foundation

public protocol ShellExecutor: Sendable {
    @discardableResult
    func run(_ command: String) async throws -> (status: Int32, output: String)
}
