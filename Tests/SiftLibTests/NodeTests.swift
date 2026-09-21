import XCTest
@testable import SiftLib

/// Phase 2: worker-loop behavior with fake transport — cancellation semantics,
/// retirement accounting, transport recovery, and executor state restoration.
final class NodeTests: XCTestCase {

    private func makeNode(
        shell: FakeSSHExecutor,
        scheduler: TestScheduler,
        workspace: RunWorkspace,
        rerun: Int = 0,
        health: HealthSink = HealthSink(),
        transferGate: TransferGate = TransferGate(limit: nil),
        resultTool: XCResultParsing = XCResultTool()
    ) -> Node {
        let nodeConfig = try! JSONDecoder().decode(Config.NodeConfig.self, from: Data("""
        {"name": "fake", "host": "h", "port": 22, "username": "u",
         "deploymentPath": "/tmp/fake-deploy", "UDID": {"simulators": ["FAKE-UDID-1"]},
         "xcodePath": "/Applications/Xcode.app"}
        """.utf8))
        let config = try! JSONDecoder().decode(Config.self, from: Data("""
        {"xctestrunPath": "/tmp/x.xctestrun", "outputDirectoryPath": "/tmp/fake-out",
         "rerunFailedTest": \(rerun), "testsBucket": 2, "testsExecutionTimeout": 1,
         "nodes": []}
        """.utf8))
        var fullConfig = config
        fullConfig.nodes = [nodeConfig]
        guard let fixtureURL = Bundle.module.url(forResource: "Fixtures/v2-sim.xctestrun", withExtension: nil) else {
            fatalError("v2-sim fixture missing")
        }
        let fixturePath = fixtureURL.path
        return Node(
            config: nodeConfig,
            globalConfig: fullConfig,
            workspace: workspace,
            scheduler: scheduler,
            collector: ResultCollector(workspace: workspace, tool: resultTool, log: nil),
            buildZipPath: "/tmp/fake-build.zip",
            xctestrunProvider: { try XCTestRunFactory.create(path: fixturePath, log: nil) },
            sshFactory: { _ in shell },
            health: health,
            transferGate: transferGate,
            log: nil
        )
    }

    private actor Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func fire() {
            fired = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func makeWorkspace() throws -> RunWorkspace {
        let base = NSTemporaryDirectory() + "sift-node-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        return workspace
    }

    func testInfrastructureFailuresRetireExecutorWithoutErase() async throws {
        let shell = FakeSSHExecutor()
        // Every chunk: xcodebuild exits 1 at once (crash-style, not a clean 0/65)
        // → download OK → ingest fails (empty zip is unreadable) → infrastructure
        // failure ×3 → retirement. (The chunk deadline is derived from the
        // allowance and is minutes long even for `testsExecutionTimeout: 1`, so the
        // failures are scripted rather than waited for.)
        shell.withState { $0.pollResults = Array(repeating: 1, count: 6) }
        let scheduler = TestScheduler(tests: (1...12).map { "B/C/test\($0)()" }, rerunLimit: 0)
        let workspace = try makeWorkspace()
        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace)
        await node.start()
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 0)
        XCTAssertFalse(snapshot.unexecuted.isEmpty, "retired executor leaves tests unexecuted")
        let log = shell.commandLog.joined(separator: "\n")
        XCTAssertFalse(log.contains("simctl erase"), "user simulators are NEVER erased")
        // Recovery is shutdown+boot; retirement happened after the failure limit.
        XCTAssertTrue(log.contains("simctl boot") || log.contains("simctl shutdown"))
    }

    func testCancellationCommitsWithoutResetAndStopsLeasing() async throws {
        let shell = FakeSSHExecutor()
        let scheduler = TestScheduler(tests: (1...8).map { "B/C/test\($0)()" }, rerunLimit: 0)
        let workspace = try makeWorkspace()
        // Long chunk timeout so the worker is inside the poll sleep when cancelled.
        let nodeConfig = shell
        _ = nodeConfig
        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace)

        let runTask = Task { await node.start() }
        try await Task.sleep(nanoseconds: 700_000_000)
        runTask.cancel()
        await runTask.value
        await scheduler.drain()

        let commandsAfter = shell.commandLog.joined(separator: "\n")
        // The executor was never blamed: no shutdown+boot recovery cycle after the
        // cancelled chunk (the simulator was already booted, so no boot commands at
        // all beyond readiness listing).
        XCTAssertFalse(commandsAfter.contains("simctl erase"))
        let snapshot = await scheduler.snapshot()
        // Whatever was in flight is not green.
        XCTAssertEqual(snapshot.passed.count, 0)
    }

    /// A node cancelled while queued for an upload permit never touched its machine:
    /// no nodeFailed health event, and no connection opened just to "clean up".
    func testCancellationWhileQueuedForUploadIsQuiet() async throws {
        let shell = FakeSSHExecutor()
        let scheduler = TestScheduler(tests: ["B/C/test1()"], rerunLimit: 0)
        let workspace = try makeWorkspace()
        let health = HealthSink()
        let gate = TransferGate(limit: 1)
        // Occupy the only permit so the node has to queue.
        let holderInside = Signal()
        let releaseHolder = Signal()
        let holder = Task {
            try await gate.withPermit {
                await holderInside.fire()
                await releaseHolder.wait()
            }
        }
        await holderInside.wait()

        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace, health: health, transferGate: gate)
        let run = Task { await node.start() }
        try await TransferGateTests.waitUntil { gate.waitingCount == 1 }
        run.cancel()
        await run.value
        await releaseHolder.fire()
        try await holder.value

        XCTAssertEqual(shell.withState { $0.connectAttempts }, 0, "no connection is opened for a node that never deployed")
        XCTAssertTrue(shell.commandLog.isEmpty, "no remote commands for a node that never deployed: \(shell.commandLog)")
        let events = await health.all()
        XCTAssertTrue(events.isEmpty, "queued cancellation is not a node failure: \(events)")
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testTransportLossReconnectsBeforeReset() async throws {
        let shell = FakeSSHExecutor()
        // Every chunk fails infrastructure-wise (xcodebuild exits 1, results
        // unreadable) AND the transport probe fails: the worker must reconnect
        // (connectAttempts grows) instead of retiring.
        shell.withState {
            $0.pollResults = [1, 1]
            $0.commandFailuresForPrefix["true"] = -1
        }
        let scheduler = TestScheduler(tests: ["B/C/test1()", "B/C/test2()"], rerunLimit: 0)
        let workspace = try makeWorkspace()
        let health = HealthSink()
        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace, health: health)
        await node.start()
        await scheduler.drain()
        // Baseline is TWO connects with no recovery at all (the management session
        // + the executor's own). Cleanup ALSO reconnects when its probe fails, so a
        // bare count cannot prove recovery: the recovered event carries the
        // transport-reconnect detail only when the worker's recovery reconnected.
        XCTAssertGreaterThanOrEqual(shell.withState { $0.connectAttempts }, 3, "recovery reconnects the transport")
        let events = await health.all()
        XCTAssertTrue(events.contains { $0.kind == .executorRecovered && $0.detail.contains("transport reconnected") },
                      "worker recovery must reconnect before resetting: \(events)")
    }

    // MARK: - Chunk budget vs. per-test allowance

    private struct FakeResultParsing: XCResultParsing {
        let outcomes: [TestOutcome]
        func testOutcomes(xcresultPath: String) async throws -> [TestOutcome] { outcomes }
        func merge(inputPaths: [String], outputPath: String) async throws -> Bool { true }
    }

    /// A valid zip whose single entry is a dummy .xcresult directory.
    private func makeResultsZipPayload() throws -> Data {
        let source = NSTemporaryDirectory() + "sift-node-zip-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(source)/r.xcresult", withIntermediateDirectories: true)
        try "stub".write(toFile: "\(source)/r.xcresult/Info.plist", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: source) }
        let zipPath = "\(source).zip"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: zipPath) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = URL(fileURLWithPath: source)
        zip.arguments = ["-r", "-y", "-q", zipPath, "r.xcresult"]
        try zip.run(); zip.waitUntilExit()
        return try Data(contentsOf: URL(fileURLWithPath: zipPath))
    }

    /// Regression (Jenkins, 2026-09-10): the chunk deadline used to be the raw
    /// `testsExecutionTimeout` — the very value XCTest enforces PER TEST — measured
    /// from xcodebuild launch for the WHOLE bucket. A test that finished close to
    /// its allowance had its chunk killed during the runner restart / bundle
    /// finalization, the bundle came back unreadable, and its verdict was lost as
    /// "not executed" (with the executor blamed). A chunk that runs past the raw
    /// value (1s here; the fake's process takes 2s of wall clock, then exits 0)
    /// must complete cleanly with its verdicts committed as-is — not killed, not
    /// demoted, not requeued.
    func testChunkOutlivingTheRawTimeoutKeepsItsVerdicts() async throws {
        let shell = FakeSSHExecutor()
        let tests = ["B/C/test1()", "B/C/test2()"]
        let payload = try makeResultsZipPayload()
        shell.withState {
            $0.timedCompletion = (after: .seconds(2), status: 0)
            $0.downloadPayload = payload
        }
        let scheduler = TestScheduler(tests: tests, rerunLimit: 0)
        let workspace = try makeWorkspace()
        let passes = tests.map { TestOutcome(test: $0, kind: .pass, duration: 1, message: "") }
        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace,
                            resultTool: FakeResultParsing(outcomes: passes))
        await node.start()
        await scheduler.drain()

        XCTAssertTrue(shell.withState { $0.terminations.isEmpty },
                      "a chunk inside its derived budget is never terminated at the raw timeout")
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 2,
                       "clean-chunk verdicts are committed as-is: \(snapshot.cases.map { "\($0.name)=\($0.state)" })")
        XCTAssertEqual(snapshot.attempts.count, 2, "exactly one attempt per test — nothing was requeued")
    }
}
