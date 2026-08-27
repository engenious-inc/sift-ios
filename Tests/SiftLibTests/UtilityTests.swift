import XCTest
@testable import SiftLib

final class UtilityTests: XCTestCase {

    // MARK: - Shell quoting

    func testShellQuotingNeutralizesMetacharacters() async throws {
        let hostile = #"$(rm -rf /tmp/nope); `echo hacked` && ' || "quoted""#
        let result = try await Run().run("printf %s \(hostile.shellQuoted)")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, hostile)
    }

    func testShellQuotingHandlesSpacesAndUnicode() async throws {
        let value = "path with spaces/и юникод/emoji 🚀"
        let result = try await Run().run("printf %s \(value.shellQuoted)")
        XCTAssertEqual(result.output, value)
    }

    // MARK: - CommandLineExecutor

    func testChecksNonzeroStatusAndCapturesStderr() async {
        do {
            _ = try await Run().runChecked("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.status, 3)
            XCTAssertTrue(error.stderr.contains("err"))
            XCTAssertTrue(error.stdout.contains("out"))
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testLargeOutputIsNotTruncatedOrReordered() async throws {
        // The historical bug: unordered detached tasks truncated/reordered pipe data.
        let result = try await Run().runChecked("/bin/sh", ["-c", "for i in $(seq 1 20000); do echo line-$i; done"])
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 20000)
        XCTAssertEqual(lines.first, "line-1")
        XCTAssertEqual(lines.last, "line-20000")
    }

    func testMissingExecutableThrowsInsteadOfCrashing() async {
        do {
            _ = try await Run().runChecked("/no/such/binary", [])
            XCTFail("expected throw")
        } catch {
            // any thrown error is correct; the old launch() raised an uncatchable NSException
        }
    }

    /// Process-GROUP escalation: the sh leader dies on TERM, its grandchild traps
    /// TERM and keeps respawning sleeps. Escalation keyed on the DIRECT child would
    /// stop there and leak the grandchild; group-liveness escalation must KILL it.
    func testTermIgnoringGrandchildIsKilledByGroupEscalation() async throws {
        let marker = "sift-grptest-\(UUID().uuidString.prefix(8))"
        let grandchild = "trap '' TERM; : \(marker); while :; do /bin/sleep 1; done"
        let result = try await CommandLineExecutor.launch(
            executable: "/bin/sh", arguments: ["-c", "/bin/sh -c \(grandchild.shellQuoted) & wait"],
            onCancellation: .terminateProcess, timeout: 1
        )
        // The leader dies to the group TERM — or, if the shell rides TERM out
        // inside `wait` (observed with bash-3.2), to the group KILL escalation.
        XCTAssertEqual(result.terminationReason, .uncaughtSignal)
        XCTAssertTrue([SIGTERM, SIGKILL].contains(result.status), "unexpected status \(result.status)")
        var survivorSeen = true
        for _ in 0..<20 {
            let probe = try await Run().runUnchecked("/usr/bin/pgrep", ["-f", marker])
            if probe.status != 0 { survivorSeen = false; break } // exit 1: no match
            await CommandLineExecutor.uncancellableSleep(seconds: 0.5)
        }
        if survivorSeen { // never leave a stray loop behind, even on failure
            _ = try? await Run().run("pkill -9 -f \(marker.shellQuoted)")
        }
        XCTAssertFalse(survivorSeen, "TERM-ignoring grandchild survived group escalation")
    }

    // MARK: - TestName canonicalization

    func testCanonicalization() {
        XCTAssertEqual(TestName.canonical("M/C/testA"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical("M/C/testA()"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical("  M/C/testA()\r"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical(""), "")
    }

    // MARK: - RunWorkspace

    func testWorkspaceCleanupTouchesOnlyRunDirectory() throws {
        let base = NSTemporaryDirectory() + "sift-ws-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A pre-existing user file next to the output directory must survive,
        // and so must a previous final/ — preparation never touches it.
        let bystander = "\(base)/precious-user-file.txt"
        FileManager.default.createFile(atPath: bystander, contents: Data("do not delete".utf8))
        try FileManager.default.createDirectory(atPath: "\(base)/final", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(base)/final/old-report.xml", contents: Data("previous run".utf8))

        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.workPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.stagingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/final/old-report.xml"),
                      "prepare must never delete the previous final")
        FileManager.default.createFile(atPath: "\(workspace.workPath)/scratch.txt", contents: Data())
        workspace.cleanupLocal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.workPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/final/old-report.xml"),
                      "an unpublished (failed) run leaves the previous final untouched")
    }

    func testWorkspacePublishIsAtomicAndPreservesPriorFinalUntilSuccess() throws {
        let base = NSTemporaryDirectory() + "sift-ws-pub-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/final", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(base)/final/old-report.xml", contents: Data("old".utf8))

        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        FileManager.default.createFile(atPath: "\(workspace.stagingPath)/final_result.xml", contents: Data("new".utf8))
        try workspace.publish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/final/final_result.xml"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/final/old-report.xml"),
                       "publication replaces the whole final directory")
    }

    func testWorkspaceRejectsUnsafeRunIDs() {
        XCTAssertThrowsError(try RunWorkspace(outputDirectoryPath: "/tmp/x", runID: "../escape"))
        XCTAssertThrowsError(try RunWorkspace(outputDirectoryPath: "/tmp/x", runID: "a/b"))
        XCTAssertThrowsError(try RunWorkspace(outputDirectoryPath: "/tmp/x", runID: ""))
        XCTAssertNoThrow(try RunWorkspace(outputDirectoryPath: "/tmp/x", runID: "run-1"))
    }

    func testOutputDirectoryLockIsExclusiveWithOwnerInError() throws {
        let base = NSTemporaryDirectory() + "sift-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let first = RunWorkspace(outputDirectoryPath: base)
        let second = RunWorkspace(outputDirectoryPath: base)
        let lock = try first.acquireLock()
        XCTAssertThrowsError(try second.acquireLock()) { error in
            XCTAssertTrue("\(error)".contains("owns the output directory"), "\(error)")
            XCTAssertTrue("\(error)".contains(first.runID), "error names the owner: \(error)")
        }
        lock.release()
        XCTAssertNoThrow(try second.acquireLock().release())
    }

    func testNodeSlugSanitizesAndRemoteWorkPathsDiffer() throws {
        XCTAssertEqual(RunWorkspace.nodeSlug(for: "mac-mini-1"), "mac-mini-1")
        XCTAssertEqual(RunWorkspace.nodeSlug(for: "weird name/../x"), "weird_name_.._x")
        let workspace = RunWorkspace(outputDirectoryPath: "/tmp/out")
        let a = workspace.remoteWorkPath(deploymentPath: "/deploy", nodeSlug: "node-a")
        let b = workspace.remoteWorkPath(deploymentPath: "/deploy", nodeSlug: "node-b")
        XCTAssertNotEqual(a, b, "same host+deploymentPath, different node entries → disjoint workspaces")
    }

    // MARK: - XCResult parsing (modern API, fixture recorded from a real Bulk run)

    func testModernTestResultsParsing() throws {
        guard let url = Bundle.module.url(forResource: "Fixtures/test-results-tests", withExtension: "json") else {
            throw XCTSkip("fixture missing")
        }
        // Exercise the PRODUCTION traversal against a committed real-Xcode fixture.
        let outcomes = try XCResultTool.outcomes(fromTestResultsJSON: Data(contentsOf: url))

        XCTAssertEqual(outcomes.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.test, $0) })
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_1()"]?.kind, .pass)
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_10()"]?.kind, .failed)
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_13()"]?.kind, .skipped)
        XCTAssertGreaterThan(byName["BulkTest/BulkTest/testExample_1()"]?.duration ?? 0, 0)
    }

    // MARK: - TestDiscovery demangle parsing

    func testDemangledLineParsing() {
        let discovery = TestDiscovery()
        // Committed shapes from real `xcrun swift-demangle -compact` output.
        XCTAssertEqual(
            discovery.testIdentifier(fromDemangled: "BulkTest.BulkTest.testExample_1() throws -> ()", moduleName: "BulkTest"),
            "BulkTest/BulkTest/testExample_1()"
        )
        XCTAssertEqual(
            discovery.testIdentifier(fromDemangled: "MyModule.Outer.Inner.testNested() -> ()", moduleName: "RenamedBundle"),
            "RenamedBundle/Outer/Inner/testNested()"
        )
        XCTAssertEqual(
            discovery.testIdentifier(fromDemangled: "M.C.testAsync() async throws -> ()", moduleName: "M"),
            "M/C/testAsync()"
        )
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "BulkTest.BulkTest.setUpWithError() throws -> ()", moduleName: "BulkTest"))
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "BulkTest.BulkTest.init(invocation: __C.NSInvocation?) -> BulkTest.BulkTest", moduleName: "BulkTest"))
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "not a symbol at all", moduleName: "M"))
    }

    func testDiscoveryAgainstRealBulkBinary() async throws {
        // Env-driven so the test is machine-independent: point SIFT_TEST_BULK_BINARY
        // at a built .xctest executable to enable it.
        guard let binary = ProcessInfo.processInfo.environment["SIFT_TEST_BULK_BINARY"],
              FileManager.default.fileExists(atPath: binary) else {
            throw XCTSkip("SIFT_TEST_BULK_BINARY not set or not present on this machine")
        }
        let tests = try await TestDiscovery().dump(binaryPath: binary, moduleName: "BulkTest")
        XCTAssertEqual(tests.count, 30)
        XCTAssertTrue(tests.contains("BulkTest/BulkTest/testExample_1()"))
        XCTAssertTrue(tests.contains("BulkTest/BulkTest/testExample_30()"))
        XCTAssertFalse(tests.contains { $0.contains("setUpWithError") })
    }
}
