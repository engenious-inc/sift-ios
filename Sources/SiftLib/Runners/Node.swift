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
    private let health: HealthSink
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
        health: HealthSink = HealthSink(),
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
        self.health = health
        self.log = log
        // Node-specific remote workspace: two node entries sharing host+deploymentPath
        // must never share upload/results/DerivedData/proc directories.
        let nodeSlug = RunWorkspace.nodeSlug(for: config.name)
        self.communication = SSHCommunication(
            config: config,
            remoteWorkPath: workspace.remoteWorkPath(deploymentPath: config.deploymentPath, nodeSlug: nodeSlug),
            sshFactory: sshFactory,
            health: health,
            log: log
        )
    }

    private var remoteWorkPath: String {
        workspace.remoteWorkPath(deploymentPath: config.deploymentPath, nodeSlug: RunWorkspace.nodeSlug(for: config.name))
    }

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
            await health.record(RunHealthEvent(kind: .nodeFailed, source: name, detail: "\(error)"))
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
        await runWorkerLoop(executor: executor, xctestrunPath: xctestrunPath)
        // Always runs — normal exhaustion, retirement, or cancellation — so the
        // executor can restore any state it changed (e.g. shut a booted simulator down).
        await executor.finish()
    }

    private func runWorkerLoop(executor: TestExecutor, xctestrunPath: String) async {
        do {
            try await executor.connect()
        } catch {
            log?.error("\(executor.executorID): connection failed — \(error)")
            await health.record(RunHealthEvent(kind: .executorUnavailable, source: executor.executorID, detail: "connection failed: \(error)"))
            return
        }
        guard await executor.ready() else {
            await health.record(RunHealthEvent(kind: .executorUnavailable, source: executor.executorID, detail: "failed readiness check"))
            return
        }

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
                let recovered = await recover(executor: executor)
                if !recovered || consecutiveFailures >= Node.executorFailureLimit {
                    log?.error("\(executor.executorID): retiring executor after \(consecutiveFailures) consecutive unhealthy chunks")
                    await health.record(RunHealthEvent(kind: .executorRetired, source: executor.executorID, detail: "\(consecutiveFailures) consecutive unhealthy chunks"))
                    return
                }
            case .infrastructureFailure(let description):
                consecutiveFailures += 1
                log?.error("\(executor.executorID): \(description)")
                await scheduler.complete(lease, outcomes: [])   // all tests → notExecuted, rerun-eligible
                let recovered = await recover(executor: executor)
                if !recovered || consecutiveFailures >= Node.executorFailureLimit {
                    log?.error("\(executor.executorID): retiring executor after \(consecutiveFailures) consecutive failures")
                    await health.record(RunHealthEvent(kind: .executorRetired, source: executor.executorID, detail: "\(consecutiveFailures) consecutive infrastructure failures"))
                    return
                }
            case .cancelled(let outcomes, let description):
                // Cancellation is worker control, not executor health: commit the
                // salvage, skip reset, stop leasing.
                log?.warning("\(executor.executorID): \(description)")
                await scheduler.complete(lease, outcomes: outcomes)
                return
            }
        }
        log?.message(verboseMsg: "\(executor.executorID): no more tests — worker done")
    }

    /// Failure recovery: a dead transport is repaired by reconnecting (the failure
    /// may have been the SSH session, not the device), then the executor recovers
    /// its own state (reboot for simulators — never an erase).
    private func recover(executor: TestExecutor) async -> Bool {
        var probeFailed = false
        do { _ = try await executor.ssh.run("true") } catch { probeFailed = true }
        if probeFailed {
            log?.warning("\(executor.executorID): transport lost — reconnecting")
            do { try await executor.connect() } catch {
                log?.error("\(executor.executorID): reconnect failed — \(error)")
                return false
            }
        }
        return await executor.reset()
    }

    private enum ChunkOutcome {
        case completed([TestOutcome])
        /// Real outcomes were recovered, but the chunk did not finish healthily
        /// (timeout, crash status): keep the verdicts, count the executor failure.
        case completedDegraded([TestOutcome], String)
        case infrastructureFailure(String)
        /// The run was cancelled during this chunk: commit whatever was salvaged,
        /// stop leasing, and never blame the executor (no reset, no health strike).
        case cancelled([TestOutcome], String)
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
        // never discard the results of a chunk that already ran, but it is surfaced
        // (a broken teardown can contaminate later chunks) rather than swallowed.
        do {
            if let status = try await runScript(path: tearDownScriptPath, executor: executor, tests: lease.tests), status != 0 {
                log?.warning("\(executor.executorID): teardown script exited with status \(status)")
                await health.record(RunHealthEvent(kind: .teardownFailed, source: executor.executorID, detail: "exit status \(status)"))
            }
        } catch {
            log?.warning("\(executor.executorID): teardown script failed: \(error)")
            await health.record(RunHealthEvent(kind: .teardownFailed, source: executor.executorID, detail: "\(error)"))
        }
        return outcome
    }

    private func executeAndCollect(lease: TestLease, executor: TestExecutor, xcodebuild: Xcodebuild, xctestrunPath: String) async -> ChunkOutcome {

        let chunkResult: Xcodebuild.ChunkResult
        do {
            chunkResult = try await xcodebuild.execute(
                tests: lease.tests,
                configuration: lease.configuration,
                executorType: executor.type,
                UDID: executor.UDID,
                xctestrunPath: xctestrunPath,
                workDirectory: remoteWorkPath,
                log: log
            )
        } catch {
            return .infrastructureFailure("xcodebuild failed to run: \(error)")
        }

        log?.message(verboseMsg: "\(executor.executorID): chunk finished with status \(chunkResult.status) (\(chunkResult.endReason))")

        // Chunk HEALTH comes from the observed status + end reason: a chunk that
        // exited cleanly (0/65) stays clean even if cancellation arrived while its
        // results were downloading.
        let cleanExit = chunkResult.endReason == .exited && (chunkResult.status == 0 || chunkResult.status == 65)
        let wasCancelled = chunkResult.endReason == .cancelled

        // Unhealthy chunks keep their FULL xcodebuild log locally — the 4000-byte
        // tail is console convenience; the log file is the post-mortem.
        if !cleanExit {
            await retainChunkLog(chunkResult, executor: executor)
        }

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
                if wasCancelled {
                    return .cancelled([], "run cancelled — chunk produced no verdicts for the leased tests")
                }
                return .infrastructureFailure("result bundle contains no outcomes for the leased tests — " + statusDescription(chunkResult))
            }
            // 0 = clean pass, 65 = clean run with test failures; anything else
            // (timeout 143, crashes, cancellation kill) is a degraded chunk: keep
            // failure/skip verdicts (they can only make the run redder), but a PASS
            // from a killed chunk must be re-earned in a healthy chunk — committing
            // it could turn a hung, partially-recorded run green.
            if cleanExit {
                reportOutcomes(outcomes, executor: executor)
                return .completed(outcomes)
            }
            let degraded = Node.degradeOutcomes(outcomes)
            reportOutcomes(degraded, executor: executor)
            if wasCancelled {
                return .cancelled(degraded, statusDescription(chunkResult))
            }
            return .completedDegraded(degraded, statusDescription(chunkResult))
        } catch {
            if wasCancelled {
                return .cancelled([], "run cancelled — chunk results unavailable: \(error)")
            }
            if cleanExit {
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

    /// Downloads the chunk's complete xcodebuild log into
    /// staging/logs/<node>/<udid>/<attempt>.log — published with the reports.
    private func retainChunkLog(_ result: Xcodebuild.ChunkResult, executor: TestExecutor) async {
        let directory = "\(workspace.stagingPath)/logs/\(RunWorkspace.nodeSlug(for: name))/\(executor.UDID)"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try await executor.ssh.downloadFile(
                remotePath: result.remoteLogPath,
                localPath: "\(directory)/\(result.attemptID).log",
                abortOnCancellation: false
            )
        } catch {
            log?.message(verboseMsg: "\(executor.executorID): could not retain chunk log (\(error))")
        }
    }

    private func statusDescription(_ result: Xcodebuild.ChunkResult) -> String {
        var description = "xcodebuild exited with status \(result.status)"
        switch result.endReason {
        case .timedOut: description += " (timeout — process was terminated)"
        case .cancelled: description += " (run cancelled — process was terminated)"
        case .exited: break
        }
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
        // Salvage mode: after Ctrl-C this download IS the partial report.
        try await executor.ssh.downloadFile(remotePath: remoteZipPath, localPath: localZipPath, abortOnCancellation: false)
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

    /// Uploads the script as a 0700 file and executes it BY PATH — its shebang is
    /// honored (no forced /bin/sh), argv limits don't apply, and env-var names were
    /// validated at config time. Tests are handed over via a newline-delimited
    /// manifest file (TEST_MANIFEST); TEST_NAMES stays for one release of
    /// backward compatibility.
    private func runScript(path: String?, executor: TestExecutor, tests: [String]) async throws -> Int32? {
        guard let path else { return nil }
        log?.message(verboseMsg: "\(executor.executorID): executing script \(path)")
        let script = try Data(contentsOf: URL(fileURLWithPath: path))
        let scriptID = UUID().uuidString
        let scriptsDirectory = "\(remoteWorkPath)/scripts"
        let remoteScript = "\(scriptsDirectory)/\(scriptID).script"
        let remoteManifest = "\(scriptsDirectory)/\(scriptID).tests"
        _ = try await executor.ssh.run("umask 077; mkdir -p \(scriptsDirectory.shellQuoted)")
        try await executor.ssh.uploadFile(data: script, remotePath: remoteScript)
        try await executor.ssh.uploadFile(data: Data(tests.joined(separator: "\n").utf8), remotePath: remoteManifest)
        _ = try await executor.ssh.run("chmod 700 \(remoteScript.shellQuoted)")

        var environment = [
            "TEST_NAME=\((tests.first ?? "").shellQuoted)",
            "TEST_NAMES=\(tests.joined(separator: " ").shellQuoted)",
            "TEST_MANIFEST=\(remoteManifest.shellQuoted)",
            "UDID=\(executor.UDID.shellQuoted)",
        ]
        for (key, value) in config.environmentVariables ?? [:] {
            environment.append("\(key)=\(value.shellQuoted)")
        }
        let prologue = environment.map { "export \($0)" }.joined(separator: "\n")
        let result = try await executor.ssh.run(prologue + "\n" + remoteScript.shellQuoted)
        _ = try? await executor.ssh.run("rm -f \(remoteScript.shellQuoted) \(remoteManifest.shellQuoted)")
        log?.message(verboseMsg: "\(executor.executorID): script exited \(result.status)\n\(result.output)")
        return result.status
    }
}
