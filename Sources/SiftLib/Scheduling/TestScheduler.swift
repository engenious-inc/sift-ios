import Foundation

/// A batch of tests handed to one executor. Every lease must be returned exactly once,
/// via `complete(_:outcomes:)` or `abandon(_:)`. A lease is configuration-pure: all its
/// tests run under the same test-plan configuration.
public struct TestLease: Sendable {
    public let id: UUID
    public let executorID: String
    /// Test-plan configuration these tests run under (nil: none recorded / FormatVersion 1).
    public let configuration: String?
    /// Canonical test identifiers.
    public let tests: [String]
    public let grantedAt: Date
}

/// Lease-based scheduler. Owns pending tests, retry queues, and in-flight leases in one
/// actor so there is no window where a failure has happened but is not yet rerunnable.
///
/// Exhaustion contract: `lease` returns nil only when the pending queue, the retry queue,
/// AND the in-flight set are all empty. A worker whose queues are momentarily empty while
/// other leases are in flight waits — results of those leases may produce retries that
/// this worker should pick up.
public actor TestScheduler {
    private var pending: [TestUnit]
    private var pendingRetries: [TestUnit] = []
    private var inFlight: [UUID: TestLease] = [:]
    private var cases: [TestUnit: TestCase] = [:]
    private var attempts: [TestAttempt] = []

    private let rerunLimit: Int
    private let infrastructureRetryLimit: Int
    /// True when the scheduled set spans more than one configuration — report names
    /// are then configuration-qualified.
    private let multiConfiguration: Bool
    /// Historical per-unit duration estimates (seconds). Empty = no history:
    /// scheduling stays randomized.
    private let estimates: [TestUnit: Double]
    /// Median of the known estimates — the stand-in for unknown tests.
    private let medianEstimate: Double
    private var activeExecutors: Set<String> = []
    private let log: Logging?
    /// Same monotonic clock the controller reports with (injectable for tests).
    private let monotonicNow: @Sendable () -> Double
    /// Stamped the first moment every queue AND the in-flight set are empty —
    /// the true end of test execution, before any node teardown runs.
    private var exhaustedAt: Double?

    private var waiters: [(executorID: String, maxCount: Int, continuation: CheckedContinuation<TestLease?, Never>)] = []

    public init(units: [TestUnit], rerunLimit: Int, infrastructureRetryLimit: Int = 1,
                estimates: [TestUnit: Double] = [:], log: Logging? = nil,
                monotonicNow: @escaping @Sendable () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }) {
        self.monotonicNow = monotonicNow
        var seen = Set<TestUnit>()
        var canonical: [TestUnit] = []
        for unit in units {
            let unit = TestUnit(configuration: unit.configuration, test: TestName.canonical(unit.test))
            guard !unit.test.isEmpty, seen.insert(unit).inserted else { continue }
            canonical.append(unit)
        }
        self.estimates = estimates
        let known = canonical.compactMap { estimates[$0] }.sorted()
        // Lower-middle median: for an even count, prefer the smaller middle value so
        // unknown tests never tie with (and randomly outrank) a genuinely slow one.
        self.medianEstimate = known.isEmpty ? 0 : known[(known.count - 1) / 2]
        // Longest-estimated first (unknowns assume the median) so the slowest tests
        // can never land as the final tail; shuffle first for random tie-breaks.
        let shuffled = canonical.shuffled()
        if known.isEmpty {
            self.pending = shuffled
        } else {
            let median = self.medianEstimate
            self.pending = shuffled.sorted { (estimates[$0] ?? median) > (estimates[$1] ?? median) }
        }
        self.rerunLimit = rerunLimit
        self.infrastructureRetryLimit = infrastructureRetryLimit
        self.multiConfiguration = Set(canonical.map(\.configuration)).count > 1
        self.log = log
        for unit in canonical {
            cases[unit] = TestCase(
                name: unit.reportName(multiConfiguration: multiConfiguration),
                state: .unexecuted, launchCounter: 0,
                infrastructureAttempts: 0, duration: 0, message: "",
                configuration: unit.configuration
            )
        }
    }

    /// Single-configuration convenience (also keeps FormatVersion 1 call sites simple).
    public init(tests: [String], rerunLimit: Int, infrastructureRetryLimit: Int = 1, log: Logging? = nil) {
        self.init(
            units: tests.map { TestUnit(configuration: nil, test: $0) },
            rerunLimit: rerunLimit,
            infrastructureRetryLimit: infrastructureRetryLimit,
            log: log
        )
    }

    public var count: Int { cases.count }

    // MARK: - Leasing

    public func lease(maxCount: Int, executorID: String) async -> TestLease? {
        activeExecutors.insert(executorID)
        let amount = max(1, maxCount)
        if let lease = makeLease(maxCount: amount, executorID: executorID) {
            return lease
        }
        if inFlight.isEmpty {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiters.append((executorID, amount, continuation))
        }
    }

    /// Pulls up to `maxCount` units of ONE configuration (the first candidate's),
    /// preserving queue order for every other configuration.
    private func takeUnits(from queue: inout [TestUnit], upTo maxCount: Int) -> [TestUnit] {
        guard let first = queue.first else { return [] }
        let configuration = first.configuration
        var taken: [TestUnit] = []
        var remaining: [TestUnit] = []
        for unit in queue {
            if taken.count < maxCount, unit.configuration == configuration {
                taken.append(unit)
            } else {
                remaining.append(unit)
            }
        }
        queue = remaining
        return taken
    }

    /// Near exhaustion, big buckets create a ragged tail (one executor grinding a
    /// final 4-test chunk while the rest idle). Once the estimated remaining work
    /// is under one bucket per active executor, leases shrink to single tests.
    private func effectiveLeaseSize(requested: Int) -> Int {
        guard requested > 1, medianEstimate > 0 else { return requested }
        let median = medianEstimate
        let remaining = (pending + pendingRetries).reduce(0.0) { $0 + (estimates[$1] ?? median) }
        let threshold = Double(requested) * Double(max(1, activeExecutors.count)) * median
        return remaining < threshold ? 1 : requested
    }

    private func makeLease(maxCount: Int, executorID: String) -> TestLease? {
        let amount = effectiveLeaseSize(requested: maxCount)
        var units = takeUnits(from: &pending, upTo: amount)
        if units.isEmpty {
            // Batch retries too — a rerun chunk pays one xcodebuild launch, not one per test.
            units = takeUnits(from: &pendingRetries, upTo: amount)
        }
        guard !units.isEmpty else { return nil }
        let lease = TestLease(
            id: UUID(),
            executorID: executorID,
            configuration: units[0].configuration,
            tests: units.map(\.test),
            grantedAt: Date()
        )
        inFlight[lease.id] = lease
        // Execution resumed — a premature end stamp (transient all-retired
        // window) must not survive.
        exhaustedAt = nil
        return lease
    }

    // MARK: - Completion

    private func unit(of lease: TestLease, test: String) -> TestUnit {
        TestUnit(configuration: lease.configuration, test: test)
    }

    /// Removes an executor from the active set (worker exited/retired) so tail
    /// shrinking divides remaining work by executors that can still take it.
    /// The LAST executor leaving ends execution even with work still queued
    /// (cancellation, every executor dead) — node teardown that follows must not
    /// count toward the execution span. A later lease grant clears the stamp, so
    /// a transient all-retired moment during startup cannot truncate the metric.
    public func retire(executorID: String) {
        activeExecutors.remove(executorID)
        if activeExecutors.isEmpty, exhaustedAt == nil {
            exhaustedAt = monotonicNow()
        }
    }

    /// Reports the outcomes of a lease. Tests in the lease without an outcome are treated
    /// as `.notExecuted`. Failed tests under the rerun limit and not-executed tests under
    /// the infrastructure retry limit re-enter the retry queue.
    /// `healthy: false` (timed-out/degraded/cancelled chunk) keeps the verdicts but
    /// excludes their durations from the timings store.
    public func complete(_ lease: TestLease, outcomes: [TestOutcome], healthy: Bool = true) {
        guard inFlight.removeValue(forKey: lease.id) != nil else {
            log?.warning("Scheduler: lease \(lease.id) completed twice — ignoring second completion")
            return
        }
        var outcomeByTest: [String: TestOutcome] = [:]
        for outcome in outcomes {
            outcomeByTest[TestName.canonical(outcome.test)] = outcome
        }
        let leased = Set(lease.tests)
        for name in outcomeByTest.keys where !leased.contains(name) {
            log?.warning("Scheduler: outcome for non-leased test '\(name)' — dropped")
        }
        let now = Date()
        for test in lease.tests {
            let unit = unit(of: lease, test: test)
            let outcome = outcomeByTest[test] ?? TestOutcome(test: test, kind: .notExecuted, message: "Was not executed")
            attempts.append(TestAttempt(
                test: unit.reportName(multiConfiguration: multiConfiguration),
                executorID: lease.executorID,
                kind: outcome.kind,
                duration: outcome.duration,
                message: outcome.message,
                startedAt: lease.grantedAt,
                endedAt: now
            ))
            apply(outcome, to: unit, healthy: healthy)
        }
        pump()
        markExhaustedIfDrained()
    }

    /// Returns a lease wholesale (executor died before running anything).
    /// Tests are re-queued as infrastructure retries.
    public func abandon(_ lease: TestLease) {
        guard inFlight.removeValue(forKey: lease.id) != nil else { return }
        let now = Date()
        for test in lease.tests {
            let unit = unit(of: lease, test: test)
            attempts.append(TestAttempt(
                test: unit.reportName(multiConfiguration: multiConfiguration),
                executorID: lease.executorID,
                kind: .notExecuted,
                duration: 0,
                message: "Lease abandoned (executor failed before execution)",
                startedAt: lease.grantedAt,
                endedAt: now
            ))
            apply(TestOutcome(test: test, kind: .notExecuted, message: "Executor failed before execution"), to: unit, healthy: false)
        }
        pump()
        markExhaustedIfDrained()
    }

    private func apply(_ outcome: TestOutcome, to unit: TestUnit, healthy: Bool = true) {
        guard var testCase = cases[unit] else {
            log?.warning("Scheduler: outcome for unknown test '\(unit.test)' — dropped")
            return
        }
        switch outcome.kind {
        case .pass:
            testCase.launchCounter += 1
            testCase.state = .pass
            testCase.duration = outcome.duration
            testCase.message = outcome.message
            testCase.timingEligible = healthy
        case .skipped:
            testCase.launchCounter += 1
            testCase.state = .skipped
            testCase.duration = outcome.duration
            testCase.message = outcome.message
            testCase.timingEligible = healthy
        case .failed:
            testCase.launchCounter += 1
            testCase.state = .failed
            testCase.duration = outcome.duration
            testCase.message = outcome.message
            testCase.timingEligible = healthy
            if testCase.launchCounter <= rerunLimit {
                pendingRetries.append(unit)
            }
        case .notExecuted:
            testCase.infrastructureAttempts += 1
            if testCase.launchCounter == 0 {
                // Never produced a real verdict — report as unexecuted.
                testCase.state = .unexecuted
                testCase.message = outcome.message
            }
            // else: keep the last real verdict (e.g. .failed from an earlier attempt).
            if testCase.infrastructureAttempts <= infrastructureRetryLimit {
                pendingRetries.append(unit)
            }
        }
        cases[unit] = testCase
    }

    /// Wakes waiting workers: hands out new leases while work exists; when the scheduler
    /// is fully exhausted, resumes everyone with nil.
    private func pump() {
        var remaining: [(executorID: String, maxCount: Int, continuation: CheckedContinuation<TestLease?, Never>)] = []
        var waitersToServe = waiters
        waiters = []
        while !waitersToServe.isEmpty {
            let waiter = waitersToServe.removeFirst()
            if let lease = makeLease(maxCount: waiter.maxCount, executorID: waiter.executorID) {
                waiter.continuation.resume(returning: lease)
            } else if inFlight.isEmpty {
                waiter.continuation.resume(returning: nil)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        if inFlight.isEmpty && pending.isEmpty && pendingRetries.isEmpty {
            for waiter in waiters {
                waiter.continuation.resume(returning: nil)
            }
            waiters = []
        }
    }

    /// Ends the run early (cancellation): all in-flight leases are dropped, queues cleared,
    /// waiting workers released with nil. In-flight tests keep their last recorded state.
    public func drain() {
        pending = []
        pendingRetries = []
        inFlight = [:]
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
        waiters = []
        markExhaustedIfDrained()
    }

    private func markExhaustedIfDrained() {
        guard exhaustedAt == nil, inFlight.isEmpty, pending.isEmpty, pendingRetries.isEmpty else { return }
        exhaustedAt = monotonicNow()
    }

    /// Monotonic timestamp of the moment execution truly ended (all queues and
    /// in-flight leases empty) — nil while work remains.
    public func executionEnded() -> Double? {
        exhaustedAt
    }

    // MARK: - Reporting

    public func snapshot() -> TestCasesSnapshot {
        TestCasesSnapshot(cases: cases.values.sorted { $0.name < $1.name }, attempts: attempts)
    }

    /// Per-unit durations from REAL verdicts (pass/fail) recorded in HEALTHY chunks —
    /// feeds the timings store. Degraded-chunk numbers never pollute the history.
    public func timingObservations() -> [(unit: TestUnit, duration: Double)] {
        cases.compactMap { unit, testCase in
            guard testCase.launchCounter > 0, testCase.timingEligible,
                  testCase.state == .pass || testCase.state == .failed else { return nil }
            return (unit, testCase.duration)
        }
    }
}
