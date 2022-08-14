import Foundation

public protocol ShellExecutor: Sendable {
    @discardableResult
    func run(_ command: String) throws -> (status: Int32, output: String)
}
