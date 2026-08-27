import Foundation

/// One remote (or local-over-SSH) machine: deploys the build, spins up one worker
/// per executor, and drives worker loops against the shared scheduler.
struct Node: Sendable {

    let name: String
    private let config: Config.NodeConfig
    private let workspace: RunWorkspace
    private let testsExecutionTimeout: Int
    private let setUpScriptPath: String?
    private let tearDownScriptPath: String?
    private let onlyTestConfiguration: String?
    private let skipTestConfiguration: String?
    private let allowXcodebuildParallelTesting: Bool
    private let testsBucket: Int
    private let scheduler: TestScheduler
    private let collector: ResultCollector
    private let communication: SSHCommunication
    private let sshFactory: @Sendable (Config.NodeConfig) -> SSHExecutor
    private let xctestrunProvider: @Sendable () throws -> XCTestRun
    private let buildZipPath: String
    private let log: Logging?

    /// Consecutive infrastructure failures before an executor is retired.
    private static let executorFailureLimit = 3

    init(
        config: Config.NodeConfig,
        globalConfig: Config,
        workspace: RunWorkspace,
        scheduler: TestScheduler,
        collector: ResultCollector,
        buildZipPath: String,
        xctestrunProvider: @escaping @Sendable () throws -> XCTestRun,
        sshFactory: @escaping @Sendable (Config.NodeConfig) -> SSHExecutor,
        log: Logging?
    ) {
        self.config = config
        self.name = config.name
        self.workspace = workspace
        self.testsExecutionTimeout = globalConfig.testsExecutionTimeout ?? 300
        self.setUpScriptPath = globalConfig.setUpScriptPath
        self.tearDownScriptPath = globalConfig.tearDownScriptPath
        self.onlyTestConfiguration = globalConfig.onlyTestConfiguration
        self.skipTestConfiguration = globalConfig.skipTestConfiguration
        self.allowXcodebuildParallelTesting = globalConfig.allowXcodebuildParallelTesting ?? false
        self.testsBucket = globalConfig.testsBucket
        self.scheduler = scheduler
        self.collector = collector
        self.buildZipPath = buildZipPath
        self.xctestrunProvider = xctestrunProvider
        self.sshFactory = sshFactory
        self.log = log
        self.communication = SSHCommunication(
            config: config,
            remoteWorkPath: workspace.remoteWorkPath(deploymentPath: config.deploymentPath),
            sshFactory: sshFactory,
            log: log
        )
    }

    private var remoteWorkPath: String { workspace.remoteWorkPath(deploymentPath: config.deploymentPath) }

    // MARK: - Lifecycle

    func start() async {
        do {
            try await communication.connect()
            try await communication.getBuildOnRunner(buildPath: buildZipPath)
            var xctestrun = try xctestrunProvider()
            xctestrun.addEnvironmentVariables(config.environmentVariables)
            xctestrun.add(timeout: testsExecutionTimeout)
            let xctestrunPath = try await communication.saveOnRunner(xctestrun: xctestrun)

            let executors = createExecutors()
            guard !executors.isEmpty else {
                log?.warning("\(name): no executors configured — node contributes nothing to this run")
                return
            }

            await withTaskGroup(of: Void.self) { group in
                for executor in executors {
                    group.addTask {
                        await self.runWorker(executor: executor, xctestrunPath: xctestrunPath)
                    }
                }
            }
            await communication.cleanup()
            log?.message(verboseMsg: "\(name): finished")
        } catch {
            log?.error("\(name): \(error)")
            await communication.cleanup()
        }
    }

    /// All three categories aggregate — a node may drive simulators AND devices AND its own macOS.
    private func createExecutors() -> [TestExecutor] {
        var executors: [TestExecutor] = []
        for udid in config.UDID.simulators ?? [] {
            executors.append(Simulator(UDID: udid, config: config, sshFactory: sshFactory, log: log))
        }
        for udid in config.UDID.devices ?? [] {
            executors.append(Device(type: .device, UDID: udid, config: config, sshFactory: sshFactory, log: log))
        }
        for udid in config.UDID.mac ?? [] {
            executors.append(Device(type: .macOS, UDID: udid, config: config, sshFactory: sshFactory, log: log))
        }
        return executors
    }

    // MARK: - Worker loop

    private func runWorker(executor: TestExecutor, xctestrunPath: String) async {
        do {
            try await executor.connect()
        } catch {
            log?.error("\(executor.executorID): connection failed — \(error)")
            return
        }
        guard await executor.ready() else { return }

        let xcodebuild = Xcodebuild(
            xcodePath: config.xcodePathRaw,
            shell: executor.ssh,
            testsExecutionTimeout: testsExecutionTimeout,
            onlyTestConfiguration: onlyTestConfiguration,
            skipTestConfiguration: skipTestConfiguration,
            allowXcodebuildParallelTesting: allowXcodebuildParallelTesting
        )

        var consecutiveFailures = 0
        while let lease = await scheduler.lease(maxCount: testsBucket, executorID: executor.executorID) {
            if Task.isCancelled {
                await scheduler.abandon(lease)
                break
            }
            let outcome = await runChunk(lease: lease, executor: executor, xcodebuild: xcodebuild, xctestrunPath: xctestrunPath)
            switch outcome {
            case .completed(let outcomes):
                consecutiveFailures = 0
                await scheduler.complete(lease, outcomes: outcomes)
            case .completedDegraded(let outcomes, let description):
                consecutiveFailures += 1
                log?.warning("\(executor.executorID): \(description)")
                await scheduler.complete(lease, outcomes: outcomes)
                let recovered = await executor.reset()
                if !recovered || consecutiveFailures >= Node.executorFailureLimit {
                    log?.error("\(executor.executorID): retiring executor after \(consecutiveFailures) consecutive unhealthy chunks")
                    return
                }
            case .infrastructureFailure(let description):
                consecutiveFailures += 1
                log?.error("\(executor.executorID): \(description)")
                await scheduler.complete(lease, outcomes: [])   // all tests → notExecuted, rerun-eligible
                let recovered = await executor.reset()
                if !recovered || consecutiveFailures >= Node.executorFailureLimit {
                    log?.error("\(executor.executorID): retiring executor after \(consecutiveFailures) consecutive failures")
                    return
                }
            }
        }
        log?.message(verboseMsg: "\(executor.executorID): no more tests — worker done")
    }

    private enum ChunkOutcome {
        case completed([TestOutcome])
        /// Real outcomes were recovered, but the chunk did not finish healthily
        /// (timeout, crash status): keep the verdicts, count the executor failure.
        case completedDegraded([TestOutcome], String)
        case infrastructureFailure(String)
    }

    private func runChunk(lease: TestLease, executor: TestExecutor, xcodebuild: Xcodebuild, xctestrunPath: String) async -> ChunkOutcome {
        // Setup script: nonzero exit means "don't run this chunk here".
        do {
            if let status = try await runScript(path: setUpScriptPath, executor: executor, tests: lease.tests), status != 0 {
                return .infrastructureFailure("setup script exited with status \(status) — chunk returned to the queue")
            }
        } catch {
            return .infrastructureFailure("setup script failed: \(error)")
        }

        log?.message(verboseMsg: "\(executor.executorID): running \(lease.tests.count) tests:\n\t- " + lease.tests.joined(separator: "\n\t- "))
        let outcome = await executeAndCollect(lease: lease, executor: executor, xcodebuild: xcodebuild, xctestrunPath: xctestrunPath)
        // Teardown always runs, in its own error boundary — a teardown failure can
        // never discard the results of a chunk that already ran.
        _ = try? await runScript(path: tearDownScriptPath, executor: executor, tests: lease.tests)
        return outcome
    }

    private func executeAndCollect(lease: TestLease, executor: TestExecutor, xcodebuild: Xcodebuild, xctestrunPath: String) async -> ChunkOutcome {

        let chunkResult: Xcodebuild.ChunkResult
        do {
            chunkResult = try await xcodebuild.execute(
                tests: lease.tests,
                executorType: executor.type,
                UDID: executor.UDID,
                xctestrunPath: xctestrunPath,
                workDirectory: remoteWorkPath,
                log: log
            )
        } catch {
            return .infrastructureFailure("xcodebuild failed to run: \(error)")
        }

        log?.message(verboseMsg: "\(executor.executorID): chunk finished with status \(chunkResult.status)")

        // Try to collect results even for unexpected statuses — partial results beat none.
        do {
            let localZip = try await downloadResults(executor: executor, remoteBundlePath: chunkResult.resultBundlePath)
            let outcomes = try await collector.ingest(zipPath: localZip)
            // A result bundle that covers none of the leased tests is not a completed
            // chunk regardless of xcodebuild's exit status — treating it as one would
            // let a corrupt-result producer drain the queue with its health counter
            // being reset every time.
            let leasedTests = Set(lease.tests)
            let coversLease = outcomes.contains { leasedTests.contains(TestName.canonical($0.test)) }
            guard coversLease else {
                return .infrastructureFailure("result bundle contains no outcomes for the leased tests — " + statusDescription(chunkResult))
            }
            // 0 = clean pass, 65 = clean run with test failures; anything else
            // (timeout 143, crashes) is a degraded chunk: keep failure/skip
            // verdicts (they can only make the run redder), but a PASS from a
            // killed chunk must be re-earned in a healthy chunk — committing it
            // could turn a hung, partially-recorded run green.
            if chunkResult.status == 0 || chunkResult.status == 65 {
                reportOutcomes(outcomes, executor: executor)
                return .completed(outcomes)
            }
            let degraded = Node.degradeOutcomes(outcomes)
            reportOutcomes(degraded, executor: executor)
            return .completedDegraded(degraded, statusDescription(chunkResult))
        } catch {
            if chunkResult.status == 0 || chunkResult.status == 65 {
                return .infrastructureFailure("tests ran (status \(chunkResult.status)) but results could not be collected: \(error)")
            }
            return .infrastructureFailure(statusDescription(chunkResult) + " — results unavailable: \(error)")
        }
    }

    /// In a chunk that did not finish healthily, run-greening verdicts (pass,
    /// skip) are demoted to notExecuted and requeued (bounded by the
    /// infrastructure retry limit) — they must be re-earned in a clean chunk.
    /// Only failures are kept: they can only make the run redder.
    static func degradeOutcomes(_ outcomes: [TestOutcome]) -> [TestOutcome] {
        outcomes.map { outcome in
            guard outcome.kind == .pass || outcome.kind == .skipped else { return outcome }
            return TestOutcome(
                test: outcome.test,
                kind: .notExecuted,
                duration: outcome.duration,
                message: "\(outcome.kind == .pass ? "Passed" : "Skipped") in a degraded chunk (xcodebuild did not exit cleanly) — requeued for confirmation"
            )
        }
    }

    private func statusDescription(_ result: Xcodebuild.ChunkResult) -> String {
        var description = "xcodebuild exited with status \(result.status)"
        if result.status == 143 { description += " (timeout — process was terminated)" }
        if !result.logTail.isEmpty {
            description += "\n--- log tail ---\n\(result.logTail)"
        }
        return description
    }

    private func downloadResults(executor: TestExecutor, remoteBundlePath: String) async throws -> String {
        let zipName = "\(UUID().uuidString).zip"
        let remoteZipPath = "\(remoteWorkPath)/\(zipName)"
        let bundleDirectory = (remoteBundlePath as NSString).deletingLastPathComponent
        let bundleName = (remoteBundlePath as NSString).lastPathComponent
        let zip = try await executor.ssh.run(
            "cd \(bundleDirectory.shellQuoted) && zip -r -X -q -0 \(remoteZipPath.shellQuoted) \(bundleName.shellQuoted)"
        )
        guard zip.status == 0 else {
            throw NSError(domain: "zipping result bundle failed on \(executor.executorID): \(zip.output)", code: 1)
        }
        let localZipPath = "\(workspace.workPath)/\(zipName)"
        try await executor.ssh.downloadFile(remotePath: remoteZipPath, localPath: localZipPath)
        _ = try? await executor.ssh.run("rm -rf \(remoteZipPath.shellQuoted) \(remoteBundlePath.shellQuoted)")
        return localZipPath
    }

    private func reportOutcomes(_ outcomes: [TestOutcome], executor: TestExecutor) {
        for outcome in outcomes {
            let duration = String(format: "%.3f", outcome.duration)
            switch outcome.kind {
            case .pass: log?.success("\(executor.executorID): \(outcome.test) - Passed: \(duration) sec.")
            case .failed: log?.failed("\(executor.executorID): \(outcome.test) - Failed: \(duration) sec.")
            case .skipped: log?.skipped("\(executor.executorID): \(outcome.test) - Skipped")
            case .notExecuted: log?.failed("\(executor.executorID): \(outcome.test) - Not executed")
            }
        }
    }

    private func runScript(path: String?, executor: TestExecutor, tests: [String]) async throws -> Int32? {
        guard let path else { return nil }
        log?.message(verboseMsg: "\(executor.executorID): executing script \(path)")
        let script = try String(contentsOfFile: path, encoding: .utf8)
        var environment = [
            "TEST_NAME=\((tests.first ?? "").shellQuoted)",
            "TEST_NAMES=\(tests.joined(separator: " ").shellQuoted)",
            "UDID=\(executor.UDID.shellQuoted)",
        ]
        for (key, value) in config.environmentVariables ?? [:] {
            environment.append("\(key)=\(value.shellQuoted)")
        }
        let prologue = environment.map { "export \($0)" }.joined(separator: "\n")
        let result = try await executor.ssh.run(prologue + "\n" + script)
        log?.message(verboseMsg: "\(executor.executorID): script exited \(result.status)\n\(result.output)")
        return result.status
    }
}
