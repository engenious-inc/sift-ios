import Foundation

/// A batch of tests handed to one executor. Every lease must be returned exactly once,
/// via `complete(_:outcomes:)` or `abandon(_:)`.
public struct TestLease: Sendable {
    public let id: UUID
    public let executorID: String
    public let tests: [String]
}

/// Lease-based scheduler. Owns pending tests, retry queues, and in-flight leases in one
/// actor so there is no window where a failure has happened but is not yet rerunnable.
///
/// Exhaustion contract: `lease` returns nil only when the pending queue, the retry queue,
/// AND the in-flight set are all empty. A worker whose queues are momentarily empty while
/// other leases are in flight waits — results of those leases may produce retries that
/// this worker should pick up.
public actor TestScheduler {
    private var pending: [String]
    private var pendingRetries: [String] = []
    private var inFlight: [UUID: TestLease] = [:]
    private var cases: [String: TestCase] = [:]

    private let rerunLimit: Int
    private let infrastructureRetryLimit: Int
    private let log: Logging?

    private var waiters: [(executorID: String, maxCount: Int, continuation: CheckedContinuation<TestLease?, Never>)] = []

    public init(tests: [String], rerunLimit: Int, infrastructureRetryLimit: Int = 1, log: Logging? = nil) {
        let canonical = TestName.canonicalList(tests)
        self.pending = canonical.shuffled()
        self.rerunLimit = rerunLimit
        self.infrastructureRetryLimit = infrastructureRetryLimit
        self.log = log
        for name in canonical {
            cases[name] = TestCase(
                name: name, state: .unexecuted, launchCounter: 0,
                infrastructureAttempts: 0, duration: 0, message: ""
            )
        }
    }

    public var count: Int { cases.count }

    // MARK: - Leasing

    public func lease(maxCount: Int, executorID: String) async -> TestLease? {
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

    private func makeLease(maxCount: Int, executorID: String) -> TestLease? {
        var tests: [String] = []
        while tests.count < maxCount, !pending.isEmpty {
            tests.append(pending.removeFirst())
        }
        if tests.isEmpty {
            // Batch retries too — a rerun chunk pays one xcodebuild launch, not one per test.
            while tests.count < maxCount, !pendingRetries.isEmpty {
                tests.append(pendingRetries.removeFirst())
            }
        }
        guard !tests.isEmpty else { return nil }
        let lease = TestLease(id: UUID(), executorID: executorID, tests: tests)
        inFlight[lease.id] = lease
        return lease
    }

    // MARK: - Completion

    /// Reports the outcomes of a lease. Tests in the lease without an outcome are treated
    /// as `.notExecuted`. Failed tests under the rerun limit and not-executed tests under
    /// the infrastructure retry limit re-enter the retry queue.
    public func complete(_ lease: TestLease, outcomes: [TestOutcome]) {
        guard inFlight.removeValue(forKey: lease.id) != nil else {
            log?.warning("Scheduler: lease \(lease.id) completed twice — ignoring second completion")
            return
        }
        var outcomeByTest: [String: TestOutcome] = [:]
        for outcome in outcomes {
            outcomeByTest[TestName.canonical(outcome.test)] = outcome
        }
        for test in lease.tests {
            let outcome = outcomeByTest[test] ?? TestOutcome(test: test, kind: .notExecuted, message: "Was not executed")
            apply(outcome, to: test)
        }
        pump()
    }

    /// Returns a lease wholesale (executor died before running anything).
    /// Tests are re-queued as infrastructure retries.
    public func abandon(_ lease: TestLease) {
        guard inFlight.removeValue(forKey: lease.id) != nil else { return }
        for test in lease.tests {
            apply(TestOutcome(test: test, kind: .notExecuted, message: "Executor failed before execution"), to: test)
        }
        pump()
    }

    private func apply(_ outcome: TestOutcome, to test: String) {
        guard var testCase = cases[test] else {
            log?.warning("Scheduler: outcome for unknown test '\(test)' — dropped")
            return
        }
        switch outcome.kind {
        case .pass:
            testCase.launchCounter += 1
            testCase.state = .pass
            testCase.duration = outcome.duration
            testCase.message = outcome.message
        case .skipped:
            testCase.launchCounter += 1
            testCase.state = .skipped
            testCase.duration = outcome.duration
            testCase.message = outcome.message
        case .failed:
            testCase.launchCounter += 1
            testCase.state = .failed
            testCase.duration = outcome.duration
            testCase.message = outcome.message
            if testCase.launchCounter <= rerunLimit {
                pendingRetries.append(test)
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
                pendingRetries.append(test)
            }
        }
        cases[test] = testCase
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
    }

    // MARK: - Reporting

    public func snapshot() -> TestCasesSnapshot {
        TestCasesSnapshot(cases: cases.values.sorted { $0.name < $1.name })
    }
}
