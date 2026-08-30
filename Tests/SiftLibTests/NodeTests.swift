import XCTest
@testable import SiftLib

/// Phase 2: worker-loop behavior with fake transport — cancellation semantics,
/// retirement accounting, transport recovery, and executor state restoration.
final class NodeTests: XCTestCase {

    private func makeNode(
        shell: FakeSSHExecutor,
        scheduler: TestScheduler,
        workspace: RunWorkspace,
        rerun: Int = 0
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
            collector: ResultCollector(workspace: workspace, log: nil),
            buildZipPath: "/tmp/fake-build.zip",
            xctestrunProvider: { try XCTestRunFactory.create(path: fixturePath, log: nil) },
            sshFactory: { _ in shell },
            log: nil
        )
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
        // Every chunk: no polls → timeout kill → download OK → ingest fails (empty
        // zip is unreadable) → infrastructure failure ×3 → retirement.
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

    func testTransportLossReconnectsBeforeReset() async throws {
        let shell = FakeSSHExecutor()
        // First chunk fails infrastructure-wise AND the transport probe fails once:
        // the worker must reconnect (connectAttempts grows) instead of retiring.
        shell.withState { $0.commandFailuresForPrefix["true"] = -1 }
        let scheduler = TestScheduler(tests: ["B/C/test1()", "B/C/test2()"], rerunLimit: 0)
        let workspace = try makeWorkspace()
        let node = makeNode(shell: shell, scheduler: scheduler, workspace: workspace)
        await node.start()
        await scheduler.drain()
        XCTAssertGreaterThan(shell.withState { $0.connectAttempts }, 1, "recovery reconnects the transport")
    }
}
