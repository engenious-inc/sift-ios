import Foundation

public enum TestExecutorType: String, Sendable {
    case simulator = "iOS Simulator"
    case device = "iOS"
    case macOS = "macOS"
}

/// One device/simulator on a node. Construction is side-effect-free;
/// `connect()` opens the SSH session.
protocol TestExecutor: Sendable {
    var type: TestExecutorType { get }
    var UDID: String { get }
    var nodeName: String { get }
    var ssh: SSHExecutor { get }
    var log: Logging? { get }

    func connect() async throws
    /// Health check before the executor joins the worker pool.
    func ready() async -> Bool
    /// Recovery after an infrastructure failure. Returns false when recovery failed.
    @discardableResult
    func reset() async -> Bool
    /// Called once when the worker loop ends (normally, retired, or cancelled) —
    /// restores any state the executor changed (e.g. shuts down a simulator Sift booted).
    func finish() async
}

extension TestExecutor {
    func finish() async {}
}

extension TestExecutor {
    var executorID: String { "\(nodeName)/\(UDID)" }
}
