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
    private let events: EventBus?
    private let transferGate: TransferGate
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
        events: EventBus? = nil,
        transferGate: TransferGate = TransferGate(limit: nil),
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
        self.events = events
        self.transferGate = transferGate
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
        var provisionedUDIDs: [String] = []
        var deploymentStarted = false
        do {
            // Connect INSIDE the permit region: a session opened minutes before its
            // upload turn could be dropped by an idle timeout while it waits.
            try await transferGate.withPermit {
                deploymentStarted = true
                try await communication.connect()
                try await communication.uploadBuild(buildPath: buildZipPath)
            }
            // A run cancelled during the upload must not spend minutes unpacking,
            // provisioning clones, and booting simulators it will never use — the
            // SSH calls below are not cancellation-aware, so check between them.
            try Task.checkCancellation()
            // Extraction runs OUTSIDE the permit: the uplink is idle during a remote
            // unzip, so the next node's transfer must not wait for it.
            try await communication.unpackBuild()
            var xctestrun = try xctestrunProvider()
            xctestrun.addEnvironmentVariables(config.environmentVariables)
            xctestrun.add(timeout: testsExecutionTimeout)
            let xctestrunPath = try await communication.saveOnRunner(xctestrun: xctestrun)
            try Task.checkCancellation()

            provisionedUDIDs = await provisionSimulators()
            let executors = createExecutors(provisionedUDIDs: provisionedUDIDs)
            guard !executors.isEmpty else {
                // The build is already deployed: every post-deployment exit must
                // remove the run directory, or a provisioning-only node whose clones
                // all failed to create leaves a multi-GB workspace behind per run.
                log?.warning("\(name): no executors configured — node contributes nothing to this run")
                await deleteProvisionedSimulators(provisionedUDIDs)
                await communication.cleanup()
                return
            }

            await withTaskGroup(of: Void.self) { group in
                for executor in executors {
                    group.addTask {
                        await self.runWorker(executor: executor, xctestrunPath: xctestrunPath)
                    }
                }
            }
            await deleteProvisionedSimulators(provisionedUDIDs)
            await communication.cleanup()
            log?.message(verboseMsg: "\(name): finished")
        } catch {
            if !deploymentStarted, error is CancellationError {
                // Cancelled while queued for an upload permit: nothing was ever opened
                // on the node — no failure to report, and a "cleanup" would only open
                // a connection to tear down nothing.
                log?.message(verboseMsg: "\(name): run cancelled before deployment started")
                return
            }
            if error is CancellationError || Task.isCancelled {
                // Cancelled mid-deployment (an aborted upload surfaces as an SSHError,
                // not CancellationError): worker control, never a node failure —
                // tear down whatever was deployed, quietly.
                log?.message(verboseMsg: "\(name): run cancelled during deployment — cleaning up")
                await deleteProvisionedSimulators(provisionedUDIDs)
                await communication.cleanup()
                return
            }
            log?.error("\(name): \(error)")
            await health.record(RunHealthEvent(kind: .nodeFailed, source: name, detail: "\(error)"))
            await deleteProvisionedSimulators(provisionedUDIDs)
            await communication.cleanup()
        }
    }

    // MARK: - Simulator auto-provisioning (Sift-owned clones)

    /// Creates the configured number of clones named `sift-<runID>-<i>`. A creation
    /// failure is a health event, not a run abort — whatever was created still works.
    private func provisionSimulators() async -> [String] {
        guard let provision = config.provisionSimulators else { return [] }
        let developerDir = "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); "
        var udids: [String] = []
        for index in 0..<provision.count {
            let simulatorName = "sift-\(workspace.runID.prefix(8))-\(index)"
            var command = developerDir + "xcrun simctl create \(simulatorName.shellQuoted) \(provision.deviceType.shellQuoted)"
            if let runtime = provision.runtime {
                command += " \(runtime.shellQuoted)"
            }
            guard let result = try? await communication.ssh.run(command), result.status == 0 else {
                let detail = "simctl create failed for \(provision.deviceType)"
                log?.error("\(name): \(detail)")
                await health.record(RunHealthEvent(kind: .executorUnavailable, source: name, detail: detail))
                continue
            }
            let udid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { continue }
            udids.append(udid)
            log?.message("\(name): provisioned simulator \(simulatorName) (\(udid))")
        }
        return udids
    }

    /// Deletes the clones this node created. The management session sat idle for
    /// the whole test run (workers use their own connections) and may have been
    /// dropped: a failed deletion gets ONE reconnect + retry, and whatever still
    /// remains is a `cleanupIncomplete` health event naming the UDIDs — a leaked
    /// clone must never be logged as "deleted".
    private func deleteProvisionedSimulators(_ udids: [String]) async {
        guard !udids.isEmpty, config.provisionSimulators?.deleteAfterRun ?? true else { return }
        var remaining: [String] = []
        for udid in udids {
            if await deleteSimulator(udid) {
                log?.message(verboseMsg: "\(name): deleted provisioned simulator \(udid)")
            } else {
                remaining.append(udid)
            }
        }
        if !remaining.isEmpty {
            log?.warning("\(name): \(remaining.count) provisioned simulator(s) not deleted — reconnecting to retry")
            if (try? await communication.connect()) != nil {
                var stillRemaining: [String] = []
                for udid in remaining {
                    if await deleteSimulator(udid) {
                        log?.message(verboseMsg: "\(name): deleted provisioned simulator \(udid) after reconnect")
                    } else {
                        stillRemaining.append(udid)
                    }
                }
                remaining = stillRemaining
            }
        }
        for udid in remaining {
            log?.error("\(name): provisioned simulator \(udid) could not be deleted — it may remain on the node")
            await health.record(RunHealthEvent(
                kind: .cleanupIncomplete, source: name,
                detail: "provisioned simulator \(udid) may remain on the node (simctl delete failed)"
            ))
        }
    }

    /// shutdown (best effort) + delete (verified). Bounded: simctl on a wedged
    /// CoreSimulator must not hold teardown for the 15-minute command budget.
    private func deleteSimulator(_ udid: String) async -> Bool {
        let developerDir = "export DEVELOPER_DIR=\(config.developerDirPath.shellQuoted); "
        _ = try? await communication.ssh.runBounded(developerDir + "xcrun simctl shutdown \(udid.shellQuoted)", timeoutSeconds: 300)
        guard let result = try? await communication.ssh.runBounded(developerDir + "xcrun simctl delete \(udid.shellQuoted)", timeoutSeconds: 300),
              result.status == 0 else {
            return false
        }
        return true
    }

    /// All three categories aggregate — a node may drive simulators AND devices AND its own macOS.
    private func createExecutors(provisionedUDIDs: [String] = []) -> [TestExecutor] {
        var executors: [TestExecutor] = []
        for udid in provisionedUDIDs {
            executors.append(Simulator(UDID: udid, config: config, sshFactory: sshFactory, siftOwned: true, log: log))
        }
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
        // executor can restore any state it changed (e.g. shut a booted simulator
        // down) and tail-shrink accounting stops counting this executor.
        await scheduler.retire(executorID: executor.executorID)
        await executor.finish()
    }

    private func runWorkerLoop(executor: TestExecutor, xctestrunPath: String) async {
        // A cancelled run must not open a connection and boot a simulator just to
        // take a lease it will abandon.
        guard !Task.isCancelled else { return }
        do {
            try await executor.connect()
        } catch {
            log?.error("\(executor.executorID): connection failed — \(error)")
            await health.record(RunHealthEvent(kind: .executorUnavailable, source: executor.executorID, detail: "connection failed: \(error)"))
            return
        }
        guard !Task.isCancelled else { return }
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
            await events?.emit("chunkStarted", ["executor": executor.executorID, "tests": "\(lease.tests.count)"])
            let outcome = await runChunk(lease: lease, executor: executor, xcodebuild: xcodebuild, xctestrunPath: xctestrunPath)
            await emitChunkEvents(outcome, lease: lease, executor: executor)
            switch outcome {
            case .completed(let outcomes):
                consecutiveFailures = 0
                await scheduler.complete(lease, outcomes: outcomes)
            case .completedDegraded(let outcomes, let description):
                consecutiveFailures += 1
                log?.warning("\(executor.executorID): \(description)")
                await scheduler.complete(lease, outcomes: outcomes, healthy: false)
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
                await scheduler.complete(lease, outcomes: outcomes, healthy: false)
                return
            }
        }
        log?.message(verboseMsg: "\(executor.executorID): no more tests — worker done")
    }

    private func emitChunkEvents(_ outcome: ChunkOutcome, lease: TestLease, executor: TestExecutor) async {
        guard let events else { return }
        let (outcomes, state): ([TestOutcome], String)
        switch outcome {
        case .completed(let o): (outcomes, state) = (o, "completed")
        case .completedDegraded(let o, _): (outcomes, state) = (o, "degraded")
        case .infrastructureFailure: (outcomes, state) = ([], "infrastructureFailure")
        case .cancelled(let o, _): (outcomes, state) = (o, "cancelled")
        }
        for one in outcomes {
            let outcomeName: String
            switch one.kind {
            case .pass: outcomeName = "passed"
            case .failed: outcomeName = "failed"
            case .skipped: outcomeName = "skipped"
            case .notExecuted: outcomeName = "notExecuted"
            }
            await events.emit("testFinished", [
                "test": one.test, "outcome": outcomeName,
                "duration": String(format: "%.3f", one.duration),
                "executor": executor.executorID,
                "configuration": lease.configuration ?? "",
            ])
        }
        await events.emit("chunkFinished", ["executor": executor.executorID, "state": state])
    }

    /// Failure recovery: a dead transport is repaired by reconnecting (the failure
    /// may have been the SSH session, not the device), then the executor recovers
    /// its own state (reboot for simulators — never an erase). A SUCCESSFUL
    /// recovery is still recorded as a health event: a run that degraded and
    /// self-healed must not look identical to one that never degraded.
    private func recover(executor: TestExecutor) async -> Bool {
        var probeFailed = false
        // runFast: the probe that DETECTS a dead transport must fail within a
        // minute, not after the 15-minute long-command budget (× 3 strikes).
        do { _ = try await executor.ssh.runFast("true") } catch { probeFailed = true }
        if probeFailed {
            log?.warning("\(executor.executorID): transport lost — reconnecting")
            do { try await executor.connect() } catch {
                log?.error("\(executor.executorID): reconnect failed — \(error)")
                return false
            }
        }
        let recovered = await executor.reset()
        if recovered {
            await health.record(RunHealthEvent(
                kind: .executorRecovered, source: executor.executorID,
                detail: probeFailed ? "transport reconnected and executor reset after an unhealthy chunk"
                                    : "executor reset after an unhealthy chunk"
            ))
        }
        return recovered
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
            let setupStatus = try await runScript(path: setUpScriptPath, executor: executor, tests: lease.tests, cancellable: true)
            // A Ctrl-C during setup terminates the script (CancellationError below)
            // or lands just after it returned — either way the chunk must not
            // launch xcodebuild, and a nonzero exit must not blame the executor.
            if Task.isCancelled {
                return .cancelled([], "run cancelled during chunk setup")
            }
            if let setupStatus, setupStatus != 0 {
                return .infrastructureFailure("setup script exited with status \(setupStatus) — chunk returned to the queue")
            }
        } catch {
            // Ctrl-C mid-setup (e.g. the script upload aborted): worker control,
            // never an executor's fault — no blame, no reset, stop leasing.
            if error is CancellationError || Task.isCancelled {
                return .cancelled([], "run cancelled during chunk setup")
            }
            return .infrastructureFailure("setup script failed: \(error)")
        }

        log?.message(verboseMsg: "\(executor.executorID): running \(lease.tests.count) tests:\n\t- " + lease.tests.joined(separator: "\n\t- "))
        let outcome = await executeAndCollect(lease: lease, executor: executor, xcodebuild: xcodebuild, xctestrunPath: xctestrunPath)
        // Teardown always runs (to completion even under cancellation — it restores
        // state — but bounded by the chunk budget), in its own error boundary: a
        // teardown failure can never discard the results of a chunk that already
        // ran, but it is surfaced (a broken teardown can contaminate later chunks)
        // rather than swallowed.
        do {
            if let status = try await runScript(path: tearDownScriptPath, executor: executor, tests: lease.tests, cancellable: false), status != 0 {
                log?.warning("\(executor.executorID): teardown script exited with status \(status)")
                // A teardown disturbed by the cancellation itself is not a failure.
                if !Task.isCancelled {
                    await health.record(RunHealthEvent(kind: .teardownFailed, source: executor.executorID, detail: "exit status \(status)"))
                }
            }
        } catch {
            log?.warning("\(executor.executorID): teardown script failed: \(error)")
            // A teardown aborted BY the cancellation is not a teardown failure.
            if !(error is CancellationError) && !Task.isCancelled {
                await health.record(RunHealthEvent(kind: .teardownFailed, source: executor.executorID, detail: "\(error)"))
            }
        }
        // Cancellation observed at chunk end (e.g. during a teardown that ran to
        // completion and exited 0): KEEP the chunk's verdicts, but the worker must
        // stop leasing — returning .completed here would lease another chunk only
        // to abandon it.
        if Task.isCancelled {
            switch outcome {
            case .cancelled:
                break // already classified, with its own description
            case .completed(let outcomes), .completedDegraded(let outcomes, _):
                return .cancelled(outcomes, "run cancelled — chunk verdicts committed, worker stopping")
            case .infrastructureFailure:
                return .cancelled([], "run cancelled — chunk produced no verdicts")
            }
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
            let download = try await downloadResults(executor: executor, remoteBundlePath: chunkResult.resultBundlePath)
            let outcomes = try await collector.ingest(zipPath: download.localZipPath)
            // The remote originals go only once the local copy has been validated
            // and staged — a corrupt download must never destroy the only copy.
            // (The run-end cleanup removes them anyway if this never runs.)
            _ = try? await executor.ssh.runFast("rm -rf \(download.remoteZipPath.shellQuoted) \(chunkResult.resultBundlePath.shellQuoted)")
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

    private func downloadResults(executor: TestExecutor, remoteBundlePath: String) async throws -> (localZipPath: String, remoteZipPath: String) {
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
        return (localZipPath, remoteZipPath)
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
    ///
    /// The script runs as an OWNED background process (same pid/status/log contract
    /// as xcodebuild) polled against a wall-clock deadline of `testsExecutionTimeout`
    /// — a plain `ssh.run` has only a per-read idle timeout, so a script that keeps
    /// printing (or a hung one, under local transport) could hold the worker, and
    /// with it the whole run, forever with no way to cancel. `cancellable` (setup)
    /// terminates the script on run cancellation; teardown runs to completion
    /// within the bound because it restores node state. A deadline expiry
    /// terminates the process tree and reports status 143.
    private func runScript(path: String?, executor: TestExecutor, tests: [String], cancellable: Bool) async throws -> Int32? {
        guard let path else { return nil }
        log?.message(verboseMsg: "\(executor.executorID): executing script \(path)")
        let script = try Data(contentsOf: URL(fileURLWithPath: path))
        let scriptID = UUID().uuidString
        let scriptsDirectory = "\(remoteWorkPath)/scripts"
        let remoteScript = "\(scriptsDirectory)/\(scriptID).script"
        let remoteManifest = "\(scriptsDirectory)/\(scriptID).tests"
        _ = try await executor.ssh.runFast("umask 077; mkdir -p \(scriptsDirectory.shellQuoted)")
        try await executor.ssh.uploadFile(data: script, remotePath: remoteScript)
        // POSIX text file: every line newline-TERMINATED (so `wc -l`/`while read` see
        // the last test too).
        try await executor.ssh.uploadFile(data: Data(tests.map { $0 + "\n" }.joined().utf8), remotePath: remoteManifest)
        _ = try await executor.ssh.runFast("chmod 700 \(remoteScript.shellQuoted)")

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
        let attemptID = "script-\(scriptID)"
        let handle = try await executor.ssh.startBackgroundProcess(
            command: prologue + "\n" + remoteScript.shellQuoted,
            workDirectory: remoteWorkPath,
            attemptID: attemptID
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(testsExecutionTimeout))
        var status: Int32?
        var cancelled = false
        var timedOut = false
        do {
            while true {
                status = try await executor.ssh.pollBackgroundProcess(handle)
                if status != nil { break }
                if cancellable && Task.isCancelled {
                    cancelled = true
                    break
                }
                let remaining = clock.now.duration(to: deadline)
                if remaining <= .zero {
                    log?.error("\(executor.executorID): script \(path) exceeded \(testsExecutionTimeout)s — terminating")
                    timedOut = true
                    break
                }
                // Uncancellable: teardown polling must not be cut short by a Ctrl-C
                // (setup checks the flag explicitly above).
                let remainingSeconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                await CommandLineExecutor.uncancellableSleep(seconds: min(1, max(0.05, remainingSeconds)))
            }
        } catch {
            // A polling failure must never orphan the script: the same rule as an
            // xcodebuild attempt (a retry or recovery would otherwise overlap it).
            await executor.ssh.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            throw error
        }
        // The process bookkeeping is removed only once the process is KNOWN gone:
        // an unverified termination keeps its handle so the run-end sweep can
        // still find (and report) it.
        var processGone = status != nil
        if status == nil {
            switch await executor.ssh.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)") {
            case .confirmedDead, .notFound:
                processGone = true
            case .unverified(let reason):
                processGone = false
                log?.warning("\(executor.executorID): could not verify the script died (\(reason)) — left for the run-end sweep")
            }
            // A deadline expiry is a failure even when the script traps TERM and
            // exits 0 during the grace: a setup that did not finish in time must
            // not let the chunk proceed, and a teardown that did not is reported.
            status = timedOut ? 143 : ((try? await executor.ssh.pollBackgroundProcess(handle)) ?? 143)
        }
        let tail = (try? await executor.ssh.runFast("tail -c 4000 \(handle.logPath.shellQuoted)").output) ?? ""
        var removals = [remoteScript, remoteManifest]
        if processGone { removals.append(handle.directory) }
        _ = try? await executor.ssh.runFast("rm -rf " + removals.map(\.shellQuoted).joined(separator: " "))
        if cancelled {
            throw CancellationError()
        }
        log?.message(verboseMsg: "\(executor.executorID): script exited \(status ?? 143)\n\(tail)")
        return status ?? 143
    }
}
