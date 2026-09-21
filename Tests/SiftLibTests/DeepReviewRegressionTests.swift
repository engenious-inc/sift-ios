import XCTest
@testable import SiftLib

/// Resumes a continuation at most once, from whichever racer finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Regressions from the whole-project review that followed the SFTP memory fix:
/// every test here reproduced a real defect at HEAD 0ce2278 before its fix.
final class DeepReviewRegressionTests: XCTestCase {

    private struct Wedged: Error, CustomStringConvertible {
        let description = "operation wedged past its deadline"
    }

    /// Races `body` against a deadline so a hang FAILS instead of stalling the suite.
    /// Deliberately NOT a task group: a group awaits every child, so a body that
    /// ignores cancellation (the launcher under `.runToCompletion`) would stall the
    /// suite past the deadline instead of failing at it. The stuck task is
    /// abandoned; whichever side finishes first resumes the caller.
    private func within<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let worker = Task {
                do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                worker.cancel()
                once.resume(.failure(Wedged()))
            }
        }
    }

    // MARK: - Process layer

    /// A detached grandchild that keeps the pipe open after the direct child exits
    /// (a setup script starting a helper with `&` and no redirect) must not wedge
    /// the launcher. Before the fix the drain guard closed the read end, which on
    /// Darwin never resumes a readabilityHandler drain — the launcher, and with it
    /// the whole run, hung forever with no way to cancel.
    func testLeakedPipeWriterDoesNotWedgeTheLauncher() async throws {
        let marker = "sift-leak-\(UUID().uuidString.prefix(8))"
        addTeardownBlock { _ = try? await Run().run("pkill -9 -f \(marker.shellQuoted)") }
        let launch = "echo started; /bin/sh -c ': \(marker); /bin/sleep 20' & exit 0"
        let start = ContinuousClock.now
        let result = try await within(seconds: 25) {
            try await CommandLineExecutor.launch(
                executable: "/bin/sh", arguments: ["-c", launch],
                onCancellation: .runToCompletion, timeout: 30
            )
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("started"), result.stdout)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(15), "the drain guard did not release the launcher")
    }

    /// The local transport must cap captured output like the SSH transport (1 MiB
    /// tail): a noisy setup script cannot balloon controller memory.
    func testLocalTransportCapsCommandOutputTail() async throws {
        let executor = LocalExecutor(host: "", port: 22, arch: nil, hostKeyVerification: .off)
        let result = try await executor.run("head -c 3145728 /dev/zero | tr '\\0' x; printf END")
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1_048_576)
        XCTAssertTrue(result.output.hasSuffix("END"), "the TAIL must be retained")
    }

    /// The CLI ignores SIGTERM (dispatch signal source) and ignored dispositions
    /// survive exec: without SETSIGDEF every local child inherited "TERM ignored",
    /// so the TERM phase of termination was a no-op and scripts could only be KILLed.
    func testSpawnedChildrenGetDefaultSignalDispositions() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let result = try await CommandLineExecutor.launch(
            executable: "/bin/sh", arguments: ["-c", "kill -TERM $$; echo survived"],
            onCancellation: .runToCompletion, timeout: 10
        )
        XCTAssertEqual(result.terminationReason, .uncaughtSignal, "the child must die to its own TERM")
        XCTAssertEqual(result.status, SIGTERM)
        XCTAssertFalse(result.stdout.contains("survived"), "TERM was still ignored in the child")
    }

    // MARK: - Scheduler

    /// A worker cancelled while WAITING for a lease is released with nil at once —
    /// it must not sit behind another executor's in-flight lease (or a wedged
    /// worker) before it can restore its simulator and let the node tear down.
    func testCancelledLeaseWaiterIsReleasedWithNil() async throws {
        let scheduler = TestScheduler(tests: ["M/C/a()", "M/C/b()"], rerunLimit: 0)
        let firstLease = await scheduler.lease(maxCount: 1, executorID: "e1")
        let secondLease = await scheduler.lease(maxCount: 1, executorID: "e2")
        let lease1 = try XCTUnwrap(firstLease)
        let lease2 = try XCTUnwrap(secondLease)
        let waiter = Task { await scheduler.lease(maxCount: 1, executorID: "e2") }
        try await Task.sleep(nanoseconds: 200_000_000)   // let it queue behind the in-flight leases
        waiter.cancel()
        let result = try await within(seconds: 5) { await waiter.value }
        XCTAssertNil(result, "a cancelled waiter must be released without waiting for e1's lease")
        await scheduler.complete(lease1, outcomes: [TestOutcome(test: lease1.tests[0], kind: .pass)])
        await scheduler.complete(lease2, outcomes: [TestOutcome(test: lease2.tests[0], kind: .pass)])
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 2)
    }

    // MARK: - Node

    private func makeWorkspace() throws -> RunWorkspace {
        let base = NSTemporaryDirectory() + "sift-review-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        return workspace
    }

    private func makeNode(
        nodeJSON: String,
        globalJSON: String,
        shell: FakeSSHExecutor,
        scheduler: TestScheduler,
        workspace: RunWorkspace,
        health: HealthSink
    ) throws -> Node {
        let nodeConfig = try JSONDecoder().decode(Config.NodeConfig.self, from: Data(nodeJSON.utf8))
        var config = try JSONDecoder().decode(Config.self, from: Data(globalJSON.utf8))
        config.nodes = [nodeConfig]
        let fixturePath = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/v2-sim.xctestrun", withExtension: nil)).path
        return Node(
            config: nodeConfig, globalConfig: config, workspace: workspace, scheduler: scheduler,
            collector: ResultCollector(workspace: workspace, log: nil), buildZipPath: "/tmp/fake-build.zip",
            xctestrunProvider: { try XCTestRunFactory.create(path: fixturePath, log: nil) },
            sshFactory: { _ in shell }, health: health, log: nil
        )
    }

    /// A provisioning-only node whose every `simctl create` fails has ALREADY
    /// deployed the build: the zero-executor exit must still sweep processes and
    /// remove the remote run directory (it used to return early and leak a
    /// multi-GB workspace per run).
    func testNodeWithoutExecutorsStillCleansUpRemoteWorkspace() async throws {
        let shell = FakeSSHExecutor()   // `simctl create` returns status 0 with no UDID → no executor
        let scheduler = TestScheduler(tests: ["B/C/test1()"], rerunLimit: 0)
        let health = HealthSink()
        let node = try makeNode(
            nodeJSON: """
            {"name": "prov", "host": "h", "port": 22, "username": "u", "deploymentPath": "/tmp/fake-deploy",
             "UDID": {}, "provisionSimulators": {"deviceType": "iPhone 17", "count": 1},
             "xcodePath": "/Applications/Xcode.app"}
            """,
            globalJSON: """
            {"xctestrunPath": "/tmp/x.xctestrun", "outputDirectoryPath": "/tmp/fake-out",
             "rerunFailedTest": 0, "testsBucket": 1, "testsExecutionTimeout": 1, "nodes": []}
            """,
            shell: shell, scheduler: scheduler, workspace: try makeWorkspace(), health: health
        )
        await node.start()
        await scheduler.drain()
        let log = shell.commandLog
        XCTAssertTrue(log.contains { $0.hasPrefix("SWEEP") }, "owned-process sweep must run: \(log)")
        XCTAssertTrue(log.contains { $0.contains("rm -rf") }, "remote run directory must be removed: \(log)")
        let events = await health.all()
        XCTAssertFalse(events.contains { $0.kind == .nodeFailed }, "a provisioning miss is not a node failure: \(events)")
    }

    /// A setup script is an OWNED process bounded by `testsExecutionTimeout`: one that
    /// never exits (or keeps streaming) is terminated and the chunk returned as an
    /// infrastructure failure, instead of holding the worker — and the whole run —
    /// forever with no way to cancel.
    func testSetupScriptExceedingTestsExecutionTimeoutIsTerminated() async throws {
        let scriptPath = NSTemporaryDirectory() + "sift-review-setup-\(UUID().uuidString).sh"
        try "#!/bin/sh\nsleep 300\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: scriptPath) }
        let shell = FakeSSHExecutor()   // background polls never report a status → deadline path
        let scheduler = TestScheduler(tests: ["B/C/test1()", "B/C/test2()"], rerunLimit: 0)
        let health = HealthSink()
        let node = try makeNode(
            nodeJSON: """
            {"name": "fake", "host": "h", "port": 22, "username": "u", "deploymentPath": "/tmp/fake-deploy",
             "UDID": {"simulators": ["FAKE-UDID-1"]}, "xcodePath": "/Applications/Xcode.app"}
            """,
            globalJSON: """
            {"xctestrunPath": "/tmp/x.xctestrun", "outputDirectoryPath": "/tmp/fake-out",
             "rerunFailedTest": 0, "testsBucket": 2, "testsExecutionTimeout": 1,
             "setUpScriptPath": "\(scriptPath)", "nodes": []}
            """,
            shell: shell, scheduler: scheduler, workspace: try makeWorkspace(), health: health
        )
        try await within(seconds: 60) { await node.start() }
        await scheduler.drain()
        let terminations = shell.withState { $0.terminations }
        XCTAssertTrue(terminations.contains { $0.marker.hasPrefix("sift-attempt:script-") },
                      "the hung setup script must be terminated by its deadline: \(terminations.map(\.marker))")
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 0)
        XCTAssertEqual(snapshot.unexecuted.count, 2, "nothing ran behind a failing setup")
        // Each timed-out setup is an infrastructure failure the executor recovers
        // from (never a cancellation, never a hang); the tests exhaust their
        // infrastructure retry and the queue drains.
        let events = await health.all()
        XCTAssertTrue(events.contains { $0.kind == .executorRecovered }, "\(events)")
        XCTAssertFalse(events.contains { $0.kind == .nodeFailed }, "\(events)")
    }

    /// A script that traps TERM and exits 0 during the termination grace must
    /// still be reported as timed out: before the fix the post-termination poll
    /// overwrote the deadline verdict with the script's own 0, so a setup that
    /// never finished let its chunk proceed and a teardown that never finished
    /// went unreported. (Observed through teardown: its status becomes a health
    /// event; the fake wrapper "writes" 0 after every terminate.)
    func testTimedOutScriptIsAFailureEvenIfItExitsZeroDuringTermination() async throws {
        let scriptPath = NSTemporaryDirectory() + "sift-review-teardown-\(UUID().uuidString).sh"
        try "#!/bin/sh\ntrap 'exit 0' TERM\nsleep 300\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: scriptPath) }
        let shell = FakeSSHExecutor()
        shell.withState {
            $0.pollResults = [0]          // the chunk itself completes at once
            $0.postTerminateStatus = 0    // the terminated teardown "exited 0" during the grace
        }
        let scheduler = TestScheduler(tests: ["B/C/test1()", "B/C/test2()"], rerunLimit: 0)
        let health = HealthSink()
        let node = try makeNode(
            nodeJSON: """
            {"name": "fake", "host": "h", "port": 22, "username": "u", "deploymentPath": "/tmp/fake-deploy",
             "UDID": {"simulators": ["FAKE-UDID-1"]}, "xcodePath": "/Applications/Xcode.app"}
            """,
            globalJSON: """
            {"xctestrunPath": "/tmp/x.xctestrun", "outputDirectoryPath": "/tmp/fake-out",
             "rerunFailedTest": 0, "testsBucket": 2, "testsExecutionTimeout": 1,
             "tearDownScriptPath": "\(scriptPath)", "nodes": []}
            """,
            shell: shell, scheduler: scheduler, workspace: try makeWorkspace(), health: health
        )
        try await within(seconds: 60) { await node.start() }
        await scheduler.drain()
        let terminations = shell.withState { $0.terminations }
        XCTAssertTrue(terminations.contains { $0.marker.hasPrefix("sift-attempt:script-") },
                      "the hung teardown must be terminated by its deadline: \(terminations.map(\.marker))")
        let events = await health.all()
        XCTAssertTrue(events.contains { $0.kind == .teardownFailed && $0.detail.contains("143") },
                      "a timed-out teardown is reported as 143, not as the 0 it wrote while dying: \(events)")
    }

    // MARK: - Config / workspace

    /// A malformed placeholder inside a secret must not echo the secret into the
    /// error (the CLI prints it into CI logs).
    func testUnterminatedPlaceholderErrorNeverEchoesTheValue() {
        let json = """
        {"xctestrunPath": "/tmp/x.xctestrun",
         "nodes": [{"name": "n", "host": "h", "username": "u", "password": "hunter2-${oops",
                    "deploymentPath": "/tmp/d", "UDID": {"simulators": ["S"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """
        XCTAssertThrowsError(try Config(data: Data(json.utf8), role: .list)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("unterminated"), text)
            XCTAssertFalse(text.contains("hunter2"), "secret echoed: \(text)")
        }
    }

    /// Two nodes on one machine with `/x/y` and `/x/y/` resolve to ONE remote
    /// workspace — validation must compare normalized paths.
    func testTrailingSlashDeploymentPathIsADuplicateEndpoint() {
        let json = """
        {"xctestrunPath": "/tmp/x.xctestrun", "outputDirectoryPath": "/tmp/out", "testsBucket": 1,
         "nodes": [
           {"name": "node a", "transport": "local", "deploymentPath": "/tmp/deploy", "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"},
           {"name": "node_a", "transport": "local", "deploymentPath": "/tmp/deploy/", "UDID": {"simulators": ["B"]}, "xcodePath": "/Applications/Xcode.app"}
         ]}
        """
        XCTAssertThrowsError(try Config(data: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("duplicate endpoint"), "\(error)")
        }
    }

    /// Sanitization is lossy: distinct names that sanitize identically must still
    /// get distinct (and stable) remote workspaces.
    func testNodeSlugsNeverCollideForDistinctNames() {
        XCTAssertEqual(RunWorkspace.nodeSlug(for: "worker-1"), "worker-1", "clean names are unchanged")
        let a = RunWorkspace.nodeSlug(for: "worker/a")
        let b = RunWorkspace.nodeSlug(for: "worker?a")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, RunWorkspace.nodeSlug(for: "worker/a"), "slugs are stable across calls")
        XCTAssertTrue(RunWorkspace.isSafePathComponent(a))
        XCTAssertTrue(RunWorkspace.isSafePathComponent(RunWorkspace.nodeSlug(for: "../evil")))
        // A clean name that literally equals a sanitized name's slug must still map elsewhere.
        XCTAssertNotEqual(RunWorkspace.nodeSlug(for: a), a, "a digest-shaped clean name gets its own digest")
        XCTAssertNotEqual(RunWorkspace.nodeSlug(for: a), RunWorkspace.nodeSlug(for: "worker/a"))
        // Sanity: every pair in a small hostile set is distinct.
        let names = ["worker/a", "worker?a", "worker_a", a, "node", "../evil", "..", "worker_a-00000000"]
        let slugs = names.map(RunWorkspace.nodeSlug(for:))
        XCTAssertEqual(Set(slugs).count, names.count, "\(zip(names, slugs).map { "\($0)→\($1)" })")
    }

    // MARK: - Discovery

    /// Two enabled targets sharing a `.xctest` basename are a configuration error,
    /// not a `Dictionary(uniqueKeysWithValues:)` crash.
    func testDuplicateBundleNamesAreAnErrorNotATrap() throws {
        let unit = TestBundleDescriptor(targetKey: "UnitTests", productModuleName: "Tests", bundleName: "Tests", executablePath: "/a/Tests.xctest/Tests")
        let ui = TestBundleDescriptor(targetKey: "UITests", productModuleName: "Tests", bundleName: "Tests", executablePath: "/b/Tests.xctest/Tests")
        let document = TestDiscovery.EnumerationDocument(
            errors: [], values: [.init(enabledTests: [.init(identifier: "Tests/C/test()")], disabledTests: [])]
        )
        XCTAssertThrowsError(try TestDiscovery.scheduledTests(fromEnumeration: document, configuration: nil, descriptors: [unit, ui], log: nil)) { error in
            XCTAssertTrue("\(error)".contains("share the bundle name"), "\(error)")
        }
        // The same descriptor twice is not a conflict.
        _ = try TestDiscovery.scheduledTests(fromEnumeration: document, configuration: nil, descriptors: [unit, unit], log: nil)
    }

    /// Demangle batches are bounded by bytes, never just by count (ARG_MAX).
    func testDemangleBatchesAreBoundedByBytes() {
        XCTAssertEqual(TestDiscovery.batches(of: ["aaaa", "bbbb", "cc"], maxBytes: 10), [["aaaa", "bbbb"], ["cc"]])
        XCTAssertEqual(TestDiscovery.batches(of: [String(repeating: "x", count: 50), "y"], maxBytes: 10).count, 2, "an oversized symbol goes alone")
        XCTAssertTrue(TestDiscovery.batches(of: [], maxBytes: 10).isEmpty)
    }

    /// Runtime identifiers sort numerically: iOS 18 outranks iOS 9 and loses to iOS 26.
    func testRuntimeVersionsSortNumerically() {
        let ids = ["com.apple.CoreSimulator.SimRuntime.iOS-9-0",
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                   "com.apple.CoreSimulator.SimRuntime.iOS-18-4"]
        let newestFirst = ids.sorted {
            TestDiscovery.runtimeVersion(ofIdentifier: $1).lexicographicallyPrecedes(TestDiscovery.runtimeVersion(ofIdentifier: $0))
        }
        XCTAssertEqual(newestFirst.map { $0.components(separatedBy: "iOS-").last! }, ["26-0", "18-4", "9-0"])
    }

    // MARK: - Reports

    /// Attributes are sanitized like messages, and a "/" inside a configuration
    /// name is never mistaken for a test-identity separator.
    func testJUnitAttributesAreSanitizedAndConfigurationSlashesDoNotSplitIdentity() throws {
        let cases = [
            TestCase(name: "B/C/testOne() [iOS/Debug]", state: .pass, launchCounter: 1, infrastructureAttempts: 0,
                     duration: 1, message: "", configuration: "iOS/Debug", identifier: "B/C/testOne()"),
            TestCase(name: "B/C/test\u{07}Bell()", state: .failed, launchCounter: 1, infrastructureAttempts: 0,
                     duration: 1, message: "boom", identifier: "B/C/test\u{07}Bell()"),
        ]
        let snapshot = TestCasesSnapshot(cases: cases)
        let xml = JUnit().generate(tests: snapshot, hostname: "host\u{01}x")
        let document = try XMLDocument(xmlString: xml)   // parses despite the control characters
        let testcases = try XCTUnwrap(document.nodes(forXPath: "//testcase") as? [XMLElement])
        let one = try XCTUnwrap(testcases.first { $0.attribute(forName: "name")?.stringValue == "testOne() [iOS/Debug]" })
        XCTAssertEqual(one.attribute(forName: "classname")?.stringValue, "B.C")
        let bell = try XCTUnwrap(testcases.first { $0.attribute(forName: "name")?.stringValue?.contains("Bell") == true })
        XCTAssertEqual(bell.attribute(forName: "name")?.stringValue, "testBell()")
        let suite = try XCTUnwrap(document.nodes(forXPath: "//testsuite").first as? XMLElement)
        XCTAssertEqual(suite.attribute(forName: "hostname")?.stringValue, "hostx")

        let report = JSONReport.generate(tests: snapshot, context: ReportContext(
            duration: 1, executionDuration: 1, mergeStatus: "merged", healthEvents: [], retainedArtifacts: []
        ))
        XCTAssertTrue(report.results.allSatisfy { $0.testSuite == "B/C" }, "\(report.results.map(\.testSuite))")
    }
}
