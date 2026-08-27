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
}

/// Result of running one chunk on an executor.
enum ChunkExecutionResult {
    /// xcodebuild ran (status 0 = all passed, 65 = some test failures) and the
    /// result bundle was zipped on the node at `remoteZipPath`.
    case finished(status: Int, remoteZipPath: String)
    /// The chunk could not produce a result bundle.
    case infrastructureFailure(description: String)
}

extension TestExecutor {
    var executorID: String { "\(nodeName)/\(UDID)" }
}
