import Foundation

/// One infrastructure event worth surfacing in reports and the summary —
/// node/executor failures, unverified processes, incomplete cleanup.
public struct RunHealthEvent: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case nodeFailed
        case executorRetired
        case executorUnavailable
        case processUnverified
        case cleanupIncomplete
        case teardownFailed
        case mergeFailed
    }
    public let kind: Kind
    /// "node" or "node/UDID".
    public let source: String
    public let detail: String

    public init(kind: Kind, source: String, detail: String) {
        self.kind = kind
        self.source = source
        self.detail = detail
    }
}

/// Collects health events from every node/worker during a run.
public actor HealthSink {
    private var events: [RunHealthEvent] = []
    public init() {}
    public func record(_ event: RunHealthEvent) {
        events.append(event)
    }
    public func all() -> [RunHealthEvent] {
        events
    }
}

/// Result of a full Sift run. The CLI (not the library) maps this to an exit code.
public struct RunOutcome: Sendable {
    public let snapshot: TestCasesSnapshot
    public let duration: Double
    public let mergedResultPath: String?
    public let reportsWritten: Bool
    /// True when a zero-test run was explicitly permitted (--allow-empty-tests).
    public let emptyRunAllowed: Bool
    /// Infrastructure events recorded during the run. A run can pass every test and
    /// still be degraded (a node down, spare capacity compensating) — consumers see
    /// that here instead of it hiding behind exit 0.
    public let healthEvents: [RunHealthEvent]

    init(snapshot: TestCasesSnapshot, duration: Double, mergedResultPath: String?, reportsWritten: Bool,
         emptyRunAllowed: Bool = false, healthEvents: [RunHealthEvent] = []) {
        self.snapshot = snapshot
        self.duration = duration
        self.mergedResultPath = mergedResultPath
        self.reportsWritten = reportsWritten
        self.emptyRunAllowed = emptyRunAllowed
        self.healthEvents = healthEvents
    }

    public var succeeded: Bool {
        snapshot.failed.isEmpty && snapshot.unexecuted.isEmpty && (snapshot.count > 0 || emptyRunAllowed)
    }
}
