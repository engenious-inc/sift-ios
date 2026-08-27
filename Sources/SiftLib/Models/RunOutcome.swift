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
    /// True when the xcresult merge failed (reports were still written; raw bundles published).
    public let mergeFailed: Bool
    /// Infrastructure events recorded during the run. A run can pass every test and
    /// still be degraded (a node down, spare capacity compensating) — consumers see
    /// that here instead of it hiding behind exit 0.
    public let healthEvents: [RunHealthEvent]

    init(snapshot: TestCasesSnapshot, duration: Double, mergedResultPath: String?, reportsWritten: Bool,
         emptyRunAllowed: Bool = false, mergeFailed: Bool = false, healthEvents: [RunHealthEvent] = []) {
        self.snapshot = snapshot
        self.duration = duration
        self.mergedResultPath = mergedResultPath
        self.reportsWritten = reportsWritten
        self.emptyRunAllowed = emptyRunAllowed
        self.mergeFailed = mergeFailed
        self.healthEvents = healthEvents
    }

    public var succeeded: Bool {
        snapshot.failed.isEmpty && snapshot.unexecuted.isEmpty && !mergeFailed
            && (snapshot.count > 0 || emptyRunAllowed)
    }
}

/// Everything a report needs beyond the verdicts themselves.
public struct ReportContext: Sendable {
    /// End-to-end wall time (through merge + report generation).
    public let duration: Double
    /// Test-execution span (until the scheduler drained).
    public let executionDuration: Double
    public let hostname: String
    /// "merged" | "failed" | "nothingToMerge".
    public let mergeStatus: String
    public let healthEvents: [RunHealthEvent]
    /// final/-relative paths retained for post-mortems.
    public let retainedArtifacts: [String]

    public init(duration: Double, executionDuration: Double,
                hostname: String = ProcessInfo.processInfo.hostName,
                mergeStatus: String, healthEvents: [RunHealthEvent], retainedArtifacts: [String]) {
        self.duration = duration
        self.executionDuration = executionDuration
        self.hostname = hostname
        self.mergeStatus = mergeStatus
        self.healthEvents = healthEvents
        self.retainedArtifacts = retainedArtifacts
    }
}
