import XCTest
@testable import SiftLib

/// Phase 2: chunk lifecycle against a fake executor — clean exits, deadline kills,
/// and cancellation with the salvage path — plus the chunk-budget derivation.
final class XcodebuildTests: XCTestCase {

    /// Lifecycle tests drive the deadline directly: no overheads, so the budget is
    /// exactly the (minute-rounded) allowance — 0 → immediate, 60 → 60s, 600 → 600s.
    private func makeXcodebuild(shell: FakeSSHExecutor, perTestAllowance: Int) -> Xcodebuild {
        makeXcodebuild(shell: shell, budget: ChunkBudget(perTestAllowance: perTestAllowance, fixedOverhead: 0, perTestOverhead: 0))
    }

    private func makeXcodebuild(shell: FakeSSHExecutor, budget: ChunkBudget) -> Xcodebuild {
        Xcodebuild(
            xcodePath: "/Applications/Xcode.app",
            shell: shell,
            budget: budget,
            onlyTestConfiguration: nil,
            skipTestConfiguration: nil
        )
    }

    func testCleanExitKeepsStatusAndExitedReason() async throws {
        let shell = FakeSSHExecutor()
        shell.withState { $0.pollResults = [nil, 65] }
        let result = try await makeXcodebuild(shell: shell, perTestAllowance: 60).execute(
            tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
            xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
        )
        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(result.endReason, .exited)
        XCTAssertTrue(shell.withState { $0.terminations.isEmpty }, "clean exit must not terminate")
    }

    func testCompletionAtDeadlineEdgeIsKept() async throws {
        // Deadline hits immediately; the final poll still returns a real status —
        // completed work is completed work.
        let shell = FakeSSHExecutor()
        shell.withState { $0.pollResults = [0] }
        let result = try await makeXcodebuild(shell: shell, perTestAllowance: 0).execute(
            tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
            xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.endReason, .exited)
        XCTAssertTrue(shell.withState { $0.terminations.isEmpty })
    }

    func testTimeoutTerminatesAndSynthesizes143() async throws {
        let shell = FakeSSHExecutor() // polls always nil (empty script → nil)
        let result = try await makeXcodebuild(shell: shell, perTestAllowance: 0).execute(
            tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
            xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
        )
        XCTAssertEqual(result.status, 143)
        XCTAssertEqual(result.endReason, .timedOut)
        XCTAssertEqual(shell.withState { $0.terminations.count }, 1)
        XCTAssertTrue(shell.withState { $0.terminations[0].marker.hasPrefix("sift-attempt:") })
    }

    func testCancellationTerminatesReadsWrapperStatusAndReturnsInsteadOfThrowing() async throws {
        let shell = FakeSSHExecutor()
        // Never completes on its own; after terminate, the wrapper "wrote" 143.
        shell.withState { $0.postTerminateStatus = 143 }
        let xcodebuild = makeXcodebuild(shell: shell, perTestAllowance: 600)
        let task = Task {
            try await xcodebuild.execute(
                tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
                xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000) // reach the poll sleep
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.endReason, .cancelled, "cancellation returns a result — never throws")
        XCTAssertEqual(result.status, 143)
        XCTAssertEqual(shell.withState { $0.terminations.count }, 1)
    }

    func testCancellationWithNoStatusFileStillSynthesizes143() async throws {
        let shell = FakeSSHExecutor() // postTerminateStatus stays nil
        let xcodebuild = makeXcodebuild(shell: shell, perTestAllowance: 600)
        let task = Task {
            try await xcodebuild.execute(
                tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
                xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, 143)
        XCTAssertEqual(result.endReason, .cancelled)
    }

    // MARK: - Chunk budget derivation

    /// Regression (Jenkins, 2026-09-10): with `testsExecutionTimeout: 400` a UI test
    /// that failed on its own at 379s had its chunk TERM-ed at 400s — while xcodebuild
    /// was restarting the crashed runner and finalizing the bundle — because the
    /// chunk deadline was the raw per-test allowance. The bundle was unreadable and
    /// the verdict was lost as "not executed". With production overheads, a chunk
    /// that runs past the raw allowance must simply complete.
    func testChunkOutlivingTheRawAllowanceCompletesInsteadOfBeingKilled() async throws {
        let shell = FakeSSHExecutor()
        // The process takes 2s of wall clock — twice the 1s raw allowance — then
        // exits 65. (Clock-based, not poll-based: a raw 1s deadline would poll at
        // 1s, see it still running, and kill it.)
        shell.withState { $0.timedCompletion = (after: .seconds(2), status: 65) }
        let xcodebuild = makeXcodebuild(shell: shell, budget: ChunkBudget(perTestAllowance: 1))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await xcodebuild.execute(
            tests: ["B/C/t()"], executorType: .device, UDID: "U",
            xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
        )
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .seconds(2),
                                    "the chunk must outlive the raw allowance for this test to prove anything")
        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(result.endReason, .exited)
        XCTAssertTrue(shell.withState { $0.terminations.isEmpty },
                      "a chunk inside its derived budget is never terminated")
    }

    /// XCTest rounds the configured allowance UP to whole minutes; the budget must
    /// reason about what XCTest enforces, not what the config says.
    func testBudgetRoundsTheAllowanceUpToWholeMinutesLikeXCTest() {
        XCTAssertEqual(ChunkBudget.effectiveAllowance(0), 0)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(-5), 0)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(1), 60)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(59), 60)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(60), 60)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(61), 120)
        XCTAssertEqual(ChunkBudget.effectiveAllowance(400), 420)
    }

    /// The budget scales with the tests actually LEASED (a tail lease can be
    /// smaller than `testsBucket`): every test may use its whole effective
    /// allowance in sequence, plus per-test and per-chunk overheads.
    func testBudgetScalesWithLeasedTestCountPlusOverheads() {
        let budget = ChunkBudget(perTestAllowance: 400)
        XCTAssertEqual(budget.seconds(testCount: 1), 300 + 1 * (420 + 60))
        XCTAssertEqual(budget.seconds(testCount: 10), 300 + 10 * (420 + 60))
        XCTAssertEqual(budget.seconds(testCount: 0), 300)
        XCTAssertEqual(budget.describe(testCount: 1), "780s = 300 + 1 × (420 + 60)")
        // Strictly looser than what XCTest itself permits — the old equality is the bug.
        XCTAssertGreaterThan(budget.seconds(testCount: 1), ChunkBudget.effectiveAllowance(400))
        // The pre-fix default (300s) now buys a 660s single-test budget.
        XCTAssertEqual(ChunkBudget(perTestAllowance: 300).seconds(testCount: 1), 660)
    }

    /// Config validation has no upper bound: absurd values must saturate, never
    /// trap or wrap into a negative (= instant) deadline.
    func testBudgetSaturatesInsteadOfOverflowing() {
        let huge = ChunkBudget(perTestAllowance: Int.max, fixedOverhead: Int.max, perTestOverhead: Int.max)
        XCTAssertEqual(huge.seconds(testCount: Int.max), ChunkBudget.maximumSeconds)
        XCTAssertEqual(huge.seconds(testCount: 1), ChunkBudget.maximumSeconds)
        XCTAssertEqual(ChunkBudget(perTestAllowance: 1).seconds(testCount: Int.max), ChunkBudget.maximumSeconds)
        XCTAssertEqual(ChunkBudget(perTestAllowance: 1, fixedOverhead: -1, perTestOverhead: -1).seconds(testCount: 1), 60)
        XCTAssertEqual(ChunkBudget(perTestAllowance: 1).seconds(testCount: -3), 300)
    }

    /// A saturated budget must not log a false equality (`315360000s = 300 + 1 × …`).
    func testSaturatedBudgetDescriptionSaysSoInsteadOfAFalseEquality() {
        let atCeiling = ChunkBudget(perTestAllowance: ChunkBudget.maximumSeconds)
        XCTAssertEqual(atCeiling.describe(testCount: 1),
                       "315360000s (315360000s ceiling applied to inputs or total; formula 300 + 1 × (315360000 + 60))")
        XCTAssertTrue(ChunkBudget(perTestAllowance: Int.max).describe(testCount: 1).contains("ceiling applied"))
        XCTAssertTrue(ChunkBudget(perTestAllowance: 1).describe(testCount: Int.max).contains("ceiling applied"))
        // Input clamping alone (allowance just past the ceiling, no overheads) is a
        // cap too — and the formula then shows the CLAMPED input, equal to the ceiling.
        XCTAssertEqual(ChunkBudget(perTestAllowance: ChunkBudget.maximumSeconds + 5, fixedOverhead: 0, perTestOverhead: 0)
                        .describe(testCount: 1),
                       "315360000s (315360000s ceiling applied to inputs or total; formula 0 + 1 × (315360000 + 0))")
        XCTAssertFalse(ChunkBudget(perTestAllowance: 400).describe(testCount: 10).contains("ceiling"))
    }
}
