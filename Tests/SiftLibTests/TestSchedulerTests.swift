import XCTest
@testable import SiftLib

final class TestSchedulerTests: XCTestCase {

    func testAllTestsLeasedExactlyOnce() async {
        let tests = (1...10).map { "M/C/test\($0)()" }
        let scheduler = TestScheduler(tests: tests, rerunLimit: 0)
        var leased: [String] = []
        while let lease = await scheduler.lease(maxCount: 3, executorID: "e1") {
            leased.append(contentsOf: lease.tests)
            await scheduler.complete(lease, outcomes: lease.tests.map { TestOutcome(test: $0, kind: .pass, duration: 1) })
        }
        XCTAssertEqual(leased.sorted(), tests.sorted())
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 10)
    }

    func testFailedTestInFinalBucketIsRerun() async {
        // The historical race: a failure in the LAST bucket must still be rerunnable.
        let scheduler = TestScheduler(tests: ["M/C/testA()", "M/C/testB()"], rerunLimit: 1)
        var executions: [String] = []
        while let lease = await scheduler.lease(maxCount: 2, executorID: "e1") {
            executions.append(contentsOf: lease.tests)
            let outcomes = lease.tests.map { test in
                TestOutcome(test: test, kind: test.contains("testB") ? .failed : .pass, duration: 1, message: "boom")
            }
            await scheduler.complete(lease, outcomes: outcomes)
        }
        // testB ran twice (initial + 1 rerun), testA once.
        XCTAssertEqual(executions.filter { $0.contains("testB") }.count, 2)
        XCTAssertEqual(executions.filter { $0.contains("testA") }.count, 1)
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.failed.count, 1)
        XCTAssertEqual(snapshot.failed.first?.launchCounter, 2)
    }

    func testRerunLimitRespected() async {
        let scheduler = TestScheduler(tests: ["M/C/testA()"], rerunLimit: 3)
        var launches = 0
        while let lease = await scheduler.lease(maxCount: 1, executorID: "e1") {
            launches += 1
            await scheduler.complete(lease, outcomes: [TestOutcome(test: "M/C/testA()", kind: .failed)])
        }
        XCTAssertEqual(launches, 4) // initial + 3 reruns
    }

    func testWorkerWaitsForInFlightRetries() async {
        // Worker 2 must not exit while worker 1's lease may still produce retries.
        let scheduler = TestScheduler(tests: ["M/C/testA()", "M/C/testB()"], rerunLimit: 1)
        let lease1 = await scheduler.lease(maxCount: 1, executorID: "e1")
        let lease2 = await scheduler.lease(maxCount: 1, executorID: "e2")
        XCTAssertNotNil(lease1)
        XCTAssertNotNil(lease2)

        // Worker 2's next lease request should block (in-flight leases exist).
        let waiter = Task {
            await scheduler.lease(maxCount: 1, executorID: "e2")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Worker 1 fails its test — the retry should be handed to the waiting worker 2.
        await scheduler.complete(lease1!, outcomes: [TestOutcome(test: lease1!.tests[0], kind: .failed)])
        let retryLease = await waiter.value
        XCTAssertNotNil(retryLease)
        XCTAssertEqual(retryLease?.tests, lease1?.tests)
        await scheduler.complete(retryLease!, outcomes: [TestOutcome(test: retryLease!.tests[0], kind: .pass)])
        await scheduler.complete(lease2!, outcomes: [TestOutcome(test: lease2!.tests[0], kind: .pass)])

        let final = await scheduler.lease(maxCount: 1, executorID: "e1")
        XCTAssertNil(final)
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 2)
    }

    func testInfrastructureFailureRequeuesWithoutBurningRerunLimit() async {
        let scheduler = TestScheduler(tests: ["M/C/testA()"], rerunLimit: 0, infrastructureRetryLimit: 1)
        let lease1 = await scheduler.lease(maxCount: 1, executorID: "e1")
        // Empty outcomes = infrastructure failure: the test never really ran.
        await scheduler.complete(lease1!, outcomes: [])
        // The test must come back for another executor.
        let lease2 = await scheduler.lease(maxCount: 1, executorID: "e2")
        XCTAssertNotNil(lease2)
        await scheduler.complete(lease2!, outcomes: [TestOutcome(test: "M/C/testA()", kind: .pass)])
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 1)
        XCTAssertEqual(snapshot.unexecuted.count, 0)
    }

    func testDuplicateCompletionIsIgnored() async {
        let scheduler = TestScheduler(tests: ["M/C/testA()"], rerunLimit: 5)
        let lease = await scheduler.lease(maxCount: 1, executorID: "e1")
        await scheduler.complete(lease!, outcomes: [TestOutcome(test: "M/C/testA()", kind: .failed)])
        await scheduler.complete(lease!, outcomes: [TestOutcome(test: "M/C/testA()", kind: .failed)])
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.cases.first?.launchCounter, 1)
    }

    func testDuplicateTestNamesDoNotCrashAndDedupe() {
        let names = TestName.canonicalList(["M/C/testA()", "M/C/testA", "M/C/testA()  ", "M/C/testB"])
        XCTAssertEqual(names, ["M/C/testA()", "M/C/testB()"])
    }

    func testExhaustedSchedulerReturnsNilForZeroTests() async {
        let scheduler = TestScheduler(tests: [], rerunLimit: 3)
        let lease = await scheduler.lease(maxCount: 5, executorID: "e1")
        XCTAssertNil(lease)
    }

    func testDegradedChunkPassNeverProducesGreenRun() async {
        // Codex regression scenario: a one-test chunk records a Pass, then
        // xcodebuild hangs and is killed (status 143). The pass must be demoted
        // and re-earned; if it never is, the run must NOT be green.
        let passOutcome = [TestOutcome(test: "M/C/testA()", kind: .pass, duration: 1)]
        let degraded = Node.degradeOutcomes(passOutcome)
        XCTAssertEqual(degraded.count, 1)
        XCTAssertEqual(degraded[0].kind, .notExecuted)
        // Failures and skips survive degradation untouched.
        let failOutcome = Node.degradeOutcomes([TestOutcome(test: "M/C/testB()", kind: .failed, message: "boom")])
        XCTAssertEqual(failOutcome[0].kind, .failed)

        // End-to-end through the scheduler: every chunk is degraded, retries
        // exhaust, and the final state is unexecuted (exit 1), never green.
        let scheduler = TestScheduler(tests: ["M/C/testA()"], rerunLimit: 0, infrastructureRetryLimit: 1)
        while let lease = await scheduler.lease(maxCount: 1, executorID: "sick") {
            let outcomes = Node.degradeOutcomes([TestOutcome(test: "M/C/testA()", kind: .pass, duration: 1)])
            await scheduler.complete(lease, outcomes: outcomes)
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.unexecuted.count, 1)
        XCTAssertEqual(snapshot.passed.count, 0)
        let outcome = RunOutcome(snapshot: snapshot, duration: 1, mergedResultPath: nil, reportsWritten: true)
        XCTAssertFalse(outcome.succeeded)
    }

    func testAttemptHistoryRecordsCompletionsAndAbandons() async {
        let scheduler = TestScheduler(tests: ["M/C/testA()", "M/C/testB()"], rerunLimit: 0, infrastructureRetryLimit: 0)
        let lease1 = await scheduler.lease(maxCount: 1, executorID: "e1")
        await scheduler.complete(lease1!, outcomes: [TestOutcome(test: lease1!.tests[0], kind: .pass, duration: 2)])
        let lease2 = await scheduler.lease(maxCount: 1, executorID: "e2")
        await scheduler.abandon(lease2!)
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.attempts.count, 2)
        let abandoned = snapshot.attempts.first { $0.executorID == "e2" }
        XCTAssertEqual(abandoned?.kind, .notExecuted)
        XCTAssertTrue(abandoned!.endedAt >= abandoned!.startedAt)
    }
}
