import Foundation

public protocol ShellExecutor {
    @discardableResult
    func run(_ command: String) throws -> (status: Int32, output: String)
}
