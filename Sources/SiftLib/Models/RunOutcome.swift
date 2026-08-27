import Foundation

/// Result of a full Sift run. The CLI (not the library) maps this to an exit code.
public struct RunOutcome: Sendable {
    public let snapshot: TestCasesSnapshot
    public let duration: Double
    public let mergedResultPath: String?
    public let reportsWritten: Bool

    public var succeeded: Bool {
        snapshot.failed.isEmpty && snapshot.unexecuted.isEmpty && snapshot.count > 0
    }
}
