import XCTest
@testable import SiftLib

/// Phase 2: chunk lifecycle against a fake executor — clean exits, deadline kills,
/// and cancellation with the salvage path.
final class XcodebuildTests: XCTestCase {

    private func makeXcodebuild(shell: FakeSSHExecutor, timeout: Int) -> Xcodebuild {
        Xcodebuild(
            xcodePath: "/Applications/Xcode.app",
            shell: shell,
            testsExecutionTimeout: timeout,
            onlyTestConfiguration: nil,
            skipTestConfiguration: nil
        )
    }

    func testCleanExitKeepsStatusAndExitedReason() async throws {
        let shell = FakeSSHExecutor()
        shell.withState { $0.pollResults = [nil, 65] }
        let result = try await makeXcodebuild(shell: shell, timeout: 60).execute(
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
        let result = try await makeXcodebuild(shell: shell, timeout: 0).execute(
            tests: ["B/C/t()"], executorType: .simulator, UDID: "U",
            xctestrunPath: "/x.xctestrun", workDirectory: "/wd", log: nil
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.endReason, .exited)
        XCTAssertTrue(shell.withState { $0.terminations.isEmpty })
    }

    func testTimeoutTerminatesAndSynthesizes143() async throws {
        let shell = FakeSSHExecutor() // polls always nil (empty script → nil)
        let result = try await makeXcodebuild(shell: shell, timeout: 0).execute(
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
        let xcodebuild = makeXcodebuild(shell: shell, timeout: 600)
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
        let xcodebuild = makeXcodebuild(shell: shell, timeout: 600)
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
}
