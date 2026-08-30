import Foundation

public protocol ShellExecutor: Sendable {
    @discardableResult
    func run(_ command: String) async throws -> (status: Int32, output: String)

    /// Short-timeout variant for liveness probes: on a black-holed transport this
    /// must fail within about a minute instead of `run`'s long-command budget.
    @discardableResult
    func runFast(_ command: String) async throws -> (status: Int32, output: String)

    /// Bounded variant for cleanup-time work: roomier than `runFast` so real work
    /// (a large deletion) can finish, but must not wedge shutdown for the full
    /// long-command budget if the transport dies mid-operation.
    @discardableResult
    func runBounded(_ command: String, timeoutSeconds: Int) async throws -> (status: Int32, output: String)
}

extension ShellExecutor {
    /// Transports with no long/short timeout distinction probe with plain `run`.
    @discardableResult
    public func runFast(_ command: String) async throws -> (status: Int32, output: String) {
        try await run(command)
    }

    /// Fallback for conformers with no timeout machinery (test fakes) — it cannot
    /// honor `timeoutSeconds`. Real transports must implement the bound themselves.
    @discardableResult
    public func runBounded(_ command: String, timeoutSeconds: Int) async throws -> (status: Int32, output: String) {
        try await run(command)
    }
}
