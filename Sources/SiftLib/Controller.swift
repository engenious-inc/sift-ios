import Foundation

/// Exactly four injected runtime dependencies (no service locator): a monotonic
/// now(), the local process runner, the node transport factory, and the result
/// tool (handed to the collector). Defaults are the production implementations.
public struct ControllerDependencies: Sendable {
    public var now: @Sendable () -> Double
    public var localShell: Run
    public var sshFactory: @Sendable (Config.NodeConfig) -> SSHExecutor
    var resultTool: XCResultParsing
    /// Test seam: replaces discovery entirely (hermetic Controller tests can't run
    /// xcodebuild/nm). Production leaves it nil.
    var testsProvider: (@Sendable (_ configuration: String?) async throws -> [ScheduledTest])?

    public init() {
        // CLOCK_MONOTONIC: never affected by NTP steps or wall-clock changes, so
        // reported durations are truthful even across a clock adjustment mid-run.
        self.now = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
        self.localShell = Run()
        self.sshFactory = { config in
            // The transport seam: "local" runs on this machine (no sshd, login-session
            // context); everything else goes over libssh2.
            if config.transport == .local {
                return LocalExecutor(
                    host: config.hostValue, port: config.portValue, arch: config.arch,
                    hostKeyVerification: config.hostKeyVerification ?? .acceptNew
                )
            }
            return SSH(
                host: config.hostValue,
                port: config.portValue,
                arch: config.arch,
                hostKeyVerification: config.hostKeyVerification ?? .acceptNew
            )
        }
        self.resultTool = XCResultTool()
        self.testsProvider = nil
    }
}

public struct Controller {
    private let config: Config
    private let xctestrunPath: String
    private let workspace: RunWorkspace
    private let discovery: TestDiscovery
    private let discoveryBackend: DiscoveryBackend
    private let log: Logging?

    public private(set) var bundleTests: [String] = []
    private var discoveredTests: [ScheduledTest] = []
    private var selectedConfigurations: [String?] = [nil]
    private var artifactPlatform: TestPlatform?
    private var requestedTests: [String]

    private let allowEmptyTests: Bool

    /// Repeatable list-command selectors: `enabled ∩ (onlys ?? all) ∖ skips`,
    /// overriding the config's singular selectors when present.
    private let listSelectors: (only: [String], skip: [String])?

    private let dependencies: ControllerDependencies
    private let events: EventBus?

    public init(
        config: Config,
        tests: [String]? = nil,
        allowEmptyTests: Bool = false,
        discoveryBackend: DiscoveryBackend = .enumeration,
        listSelectors: (only: [String], skip: [String])? = nil,
        dependencies: ControllerDependencies = ControllerDependencies(),
        events: EventBus? = nil,
        log: Logging?
    ) {
        self.events = events
        self.config = config
        self.xctestrunPath = config.xctestrunPath
        self.workspace = RunWorkspace(outputDirectoryPath: config.outputDirectoryPath)
        self.discovery = TestDiscovery(log: log)
        self.discoveryBackend = discoveryBackend
        self.listSelectors = listSelectors
        self.dependencies = dependencies
        self.requestedTests = tests ?? []
        self.allowEmptyTests = allowEmptyTests
        self.log = log
    }

    // MARK: - Discovery (side-effect-free; used by both `list` and `run`)

    public mutating func discoverTests() async throws -> [String] {
        let xctestrun = try XCTestRunFactory.create(path: xctestrunPath, log: log)
        // selected = enabled ∩ (only == nil ? all : {only}) ∖ {skip}; unknown names
        // and an empty selection are errors.
        let selected: [String?]
        if let listSelectors {
            // Repeatable CLI flags: validate every named configuration, then apply
            // the same algebra over the sets.
            for name in listSelectors.only { _ = try xctestrun.selectedConfigurationNames(only: name, skip: nil) }
            for name in listSelectors.skip { _ = try xctestrun.selectedConfigurationNames(only: nil, skip: name) }
            let allEnabled = try xctestrun.selectedConfigurationNames(only: nil, skip: nil)
            let afterOnly = listSelectors.only.isEmpty
                ? allEnabled
                : allEnabled.filter { name in name.map { listSelectors.only.contains($0) } ?? false }
            let result = afterOnly.filter { name in name.map { !listSelectors.skip.contains($0) } ?? true }
            guard !result.isEmpty else {
                throw XCTestRunError("configuration selection left nothing to list (only: \(listSelectors.only), skip: \(listSelectors.skip))")
            }
            selected = result
        } else {
            selected = try xctestrun.selectedConfigurationNames(
                only: config.onlyTestConfiguration,
                skip: config.skipTestConfiguration
            )
        }
        self.selectedConfigurations = selected
        self.artifactPlatform = try xctestrun.platform()
        if selected.count > 1 {
            log?.message("Running \(selected.count) test configurations: " + selected.compactMap { $0 }.joined(separator: ", "))
        }

        var all: [ScheduledTest] = []
        for configuration in selected {
            var tests: [ScheduledTest]
            if let testsProvider = dependencies.testsProvider {
                tests = try await testsProvider(configuration)
            } else {
                tests = try await discovery.tests(
                    xctestrun: xctestrun,
                    configuration: configuration,
                    backend: discoveryBackend
                )
            }
            let only = xctestrun.onlyTestIdentifiers(config: configuration)
            if !only.isEmpty {
                log?.message(verboseMsg: "OnlyTestIdentifiers:\n\(only)")
                tests = tests.filter { test in
                    guard let identifiers = only[test.bundleName], !identifiers.isEmpty else { return true }
                    return identifiers.contains { identifierMatches($0, test: test.id) }
                }
            }
            let skip = xctestrun.skipTestIdentifiers(config: configuration)
            if !skip.isEmpty {
                log?.message(verboseMsg: "SkipTestIdentifiers:\n\(skip)")
                tests = tests.filter { test in
                    guard let identifiers = skip[test.bundleName] else { return true }
                    return !identifiers.contains { identifierMatches($0, test: test.id) }
                }
            }
            all.append(contentsOf: tests)
        }

        self.discoveredTests = all
        // `list` output and the public API stay one line per unique identifier.
        var seen = Set<String>()
        self.bundleTests = all.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
        return bundleTests
    }

    /// True when `identifier` ("Class" or "Class/test") selects `test` ("Bundle/Class/test()").
    private func identifierMatches(_ identifier: String, test: String) -> Bool {
        let testComponents = test.components(separatedBy: "/").dropFirst().map { $0.replacingOccurrences(of: "()", with: "") }
        let identifierComponents = identifier.components(separatedBy: "/").map { $0.replacingOccurrences(of: "()", with: "") }
        guard identifierComponents.count <= testComponents.count else { return false }
        return zip(identifierComponents, testComponents).allSatisfy { $0 == $1 }
    }

    // MARK: - Run

    public mutating func run() async throws -> RunOutcome {
        let startTime = dependencies.now()
        // ONE terminal event per run, wherever it ends: success paths emit
        // `runFinished` after publication; EVERY thrown error lands here and emits
        // status "error" first — discovery, selector, and preflight failures included.
        do {
            return try await runGuarded(startTime: startTime)
        } catch {
            await events?.emit("runFinished", ["status": "error", "error": "\(error)"])
            await events?.finish()
            throw error
        }
    }

    private mutating func runGuarded(startTime: Double) async throws -> RunOutcome {
        _ = try await discoverTests()

        // Requested selectors are expanded against the discovered set: class/module
        // granularity works, and a typo is a selection error here — never a phantom
        // test burning infrastructure retries downstream. In a multi-configuration
        // run the same identifier is scheduled once per selected configuration.
        let selectedTests: [ScheduledTest]
        if requestedTests.isEmpty {
            selectedTests = discoveredTests
        } else {
            selectedTests = try TestSelector.expand(rawSelectors: requestedTests, against: discoveredTests)
        }
        let unitsForRun = selectedTests.map { TestUnit(configuration: $0.configurationName, test: $0.id) }

        try validateExecutorPlatforms()

        guard !unitsForRun.isEmpty else {
            if allowEmptyTests {
                // A permitted empty run still publishes REAL zero-test reports through
                // the same atomic path — stale artifacts from an older run must never
                // masquerade as this run's results.
                log?.warning("No tests to execute (--allow-empty-tests set) — publishing zero-test reports")
                let lock = try workspace.acquireLock()
                defer { lock.release() }
                try workspace.prepareLocal()
                // Error paths clean up here; the success path cleans up explicitly
                // BEFORE the terminal event — same contract as a nonempty run.
                defer {
                    if FileManager.default.fileExists(atPath: workspace.workPath),
                       let error = workspace.cleanupLocal() {
                        log?.warning("run-scratch cleanup incomplete at \(workspace.workPath): \(error)")
                    }
                }
                let snapshot = TestCasesSnapshot(cases: [])
                try writeReports(snapshot: snapshot, context: ReportContext(
                    duration: 0, executionDuration: 0,
                    mergeStatus: "nothingToMerge", healthEvents: [], retainedArtifacts: []
                ))
                try workspace.publish()
                if let cleanupError = workspace.cleanupLocal() {
                    log?.warning("run-scratch cleanup incomplete at \(workspace.workPath): \(cleanupError)")
                }
                await events?.emit("runFinished", ["status": "passed", "passed": "0", "failed": "0",
                                                  "skipped": "0", "unexecuted": "0", "duration": "0.000"])
                await events?.finish()
                return RunOutcome(
                    snapshot: snapshot,
                    duration: 0,
                    mergedResultPath: nil,
                    reportsWritten: true,
                    emptyRunAllowed: true
                )
            }
            throw XCTestRunError("No tests were discovered for execution. If an empty test list is expected, pass --allow-empty-tests.")
        }

        log?.message("Total tests for execution: \(unitsForRun.count)")
        await events?.emit("runStarted", [
            "tests": "\(unitsForRun.count)",
            "configurations": "\(selectedConfigurations.count)",
            "nodes": "\(config.nodes.count)",
        ])
        return try await executeRun(startTime: startTime, unitsForRun: unitsForRun)
    }

    private mutating func executeRun(startTime: Double, unitsForRun: [TestUnit]) async throws -> RunOutcome {
        // Serialize runs sharing this output directory; the lock dies with the process.
        let lock = try workspace.acquireLock()
        defer { lock.release() }
        try workspace.prepareLocal()
        // Error paths clean up here; the success path cleans up EXPLICITLY before
        // the terminal event so an incomplete cleanup reaches the health set.
        defer {
            if FileManager.default.fileExists(atPath: workspace.workPath),
               let error = workspace.cleanupLocal() {
                log?.warning("run-scratch cleanup incomplete at \(workspace.workPath): \(error)")
            }
        }
        let buildZipPath = try await zipBuild()

        // Historical durations drive longest-first scheduling; a missing/corrupt
        // store just means randomized order (the first run's behavior).
        var timings = TestTimings.load(outputDirectoryPath: config.outputDirectoryPath, log: log)
        let estimates = artifactPlatform.map { timings.estimates(platform: $0, units: unitsForRun) } ?? [:]
        if !estimates.isEmpty {
            log?.message(verboseMsg: "Timings store: \(estimates.count)/\(unitsForRun.count) tests have historical durations — scheduling longest-first")
        }
        let scheduler = TestScheduler(
            units: unitsForRun,
            rerunLimit: config.rerunFailedTest,
            infrastructureRetryLimit: 1,
            estimates: estimates,
            log: log,
            monotonicNow: dependencies.now
        )
        let collector = ResultCollector(workspace: workspace, tool: dependencies.resultTool, log: log)
        let health = HealthSink()

        let xctestrunPath = self.xctestrunPath
        let workspace = self.workspace
        let globalConfig = self.config
        let log = self.log

        let nodes = config.nodes.map { nodeConfig in
            Node(
                config: nodeConfig,
                globalConfig: globalConfig,
                workspace: workspace,
                scheduler: scheduler,
                collector: collector,
                buildZipPath: buildZipPath,
                xctestrunProvider: { try XCTestRunFactory.create(path: xctestrunPath, log: nil) },
                sshFactory: dependencies.sshFactory,
                health: health,
                events: events,
                log: log
            )
        }

        // Execution bracket: nodes starting → scheduler drained. Discovery and
        // packaging are set-up cost, reported only inside the end-to-end duration.
        let executionStart = dependencies.now()
        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask { await node.start() }
            }
        }
        // All workers exited — release anything still waiting (e.g. all executors dead).
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        // The scheduler stamps the moment it drained — node teardown (simulator
        // deletion, remote cleanup) happens after that and must not inflate the
        // reported execution span.
        let executionDuration = (await scheduler.executionEnded() ?? dependencies.now()) - executionStart

        // Feed real verdict durations back into the timings store for the next run.
        if let platform = artifactPlatform {
            for observation in await scheduler.timingObservations() {
                timings.record(platform: platform, unit: observation.unit, duration: observation.duration)
            }
            timings.save(outputDirectoryPath: config.outputDirectoryPath, log: log)
        }

        // Reports never depend on the merge: the snapshot's verdicts exist whether or
        // not xcresulttool cooperates. A failed merge is recorded (health event +
        // non-zero exit) and the raw per-chunk bundles are published as evidence.
        var mergeStatus = "nothingToMerge"
        var mergedPath: String?
        do {
            mergedPath = try await collector.mergeAll()
            if mergedPath != nil { mergeStatus = "merged" }
        } catch {
            mergeStatus = "failed"
            log?.error("Result merge FAILED — reports are still written; raw per-chunk bundles are published: \(error)")
            await health.record(RunHealthEvent(kind: .mergeFailed, source: "controller", detail: "\(error)"))
        }

        let healthEvents = await health.all()
        let retainedArtifacts = await collector.retainedArtifacts().map {
            $0.replacingOccurrences(of: workspace.stagingPath, with: "final")
        }
        let duration = dependencies.now() - startTime
        try writeReports(snapshot: snapshot, context: ReportContext(
            duration: duration,
            executionDuration: executionDuration,
            mergeStatus: mergeStatus,
            healthEvents: healthEvents,
            retainedArtifacts: retainedArtifacts
        ))
        // Everything was staged under the run directory; one atomic rename makes it
        // `final/` — the previous final survives any failure before this point.
        let publishedPath = try workspace.publish()
        // Scratch cleanup runs BEFORE the terminal event so an incomplete cleanup
        // reaches the health set (CLI summary, RunOutcome, exit consumers). The
        // already-published JSON report reflects pre-publication health only.
        if let cleanupError = workspace.cleanupLocal() {
            log?.warning("run-scratch cleanup incomplete at \(workspace.workPath): \(cleanupError)")
            await health.record(RunHealthEvent(
                kind: .cleanupIncomplete, source: "controller",
                detail: "local scratch \(workspace.workPath): \(cleanupError)"
            ))
        }
        let finalHealthEvents = await health.all()
        // Terminal event AFTER publication: a consumer that sees runFinished can
        // trust that `final/` exists (a failed publish emits status "error" instead).
        await events?.emit("runFinished", [
            "status": snapshot.failed.isEmpty && snapshot.unexecuted.isEmpty && mergeStatus != "failed" ? "passed" : "failed",
            "passed": "\(snapshot.passed.count)",
            "failed": "\(snapshot.failed.count)",
            "skipped": "\(snapshot.skipped.count)",
            "unexecuted": "\(snapshot.unexecuted.count)",
            "duration": String(format: "%.3f", executionDuration),
        ])
        await events?.finish()
        printSummary(snapshot: snapshot, duration: duration)

        if !finalHealthEvents.isEmpty {
            log?.warning("Infrastructure health (\(finalHealthEvents.count) event(s)):")
            for event in finalHealthEvents {
                log?.warning(before: "\t", "[\(event.kind.rawValue)] \(event.source): \(event.detail)")
            }
        }

        return RunOutcome(
            snapshot: snapshot,
            duration: duration,
            mergedResultPath: mergedPath.map { _ in "\(publishedPath)/final_result.xcresult" },
            reportsWritten: true,
            mergeFailed: mergeStatus == "failed",
            healthEvents: finalHealthEvents
        )
    }

    /// A simulator-built artifact cannot run on devices or macOS (and vice versa).
    /// Reject the run listing every incompatible node/UDID rather than failing
    /// chunk-by-chunk at execution time.
    private func validateExecutorPlatforms() throws {
        guard let platform = artifactPlatform else { return }
        var violations: [String] = []
        for node in config.nodes {
            func check(_ udids: [String]?, type: TestExecutorType, label: String) {
                guard let udids, !udids.isEmpty else { return }
                if !platform.allowedExecutorTypes.contains(type) {
                    violations.append(
                        "node '\(node.name)': \(udids.count) \(label) UDID(s) configured, but the xctestrun "
                        + "was built for \(platform.displayName)"
                    )
                }
            }
            check(node.UDID.simulators, type: .simulator, label: "simulator")
            check(node.UDID.devices, type: .device, label: "device")
            check(node.UDID.mac, type: .macOS, label: "mac")
            // Auto-provisioned clones ARE simulator capacity: a device/macOS artifact
            // with a provisioning-only node must fail here, not after creating clones.
            if let provision = node.provisionSimulators, provision.count > 0,
               !platform.allowedExecutorTypes.contains(.simulator) {
                violations.append(
                    "node '\(node.name)': provisionSimulators requests \(provision.count) simulator clone(s), "
                    + "but the xctestrun was built for \(platform.displayName)"
                )
            }
        }
        guard violations.isEmpty else {
            throw XCTestRunError(
                "Executor/platform mismatch:\n" + violations.map { "  - \($0)" }.joined(separator: "\n")
            )
        }
    }

    // MARK: - Build packaging

    private func zipBuild() async throws -> String {
        let xctestrun = try XCTestRunFactory.create(path: xctestrunPath, log: log)
        let testRootPath = xctestrun.testRootPath
        // Union of dependent products across every selected configuration.
        let dependentPaths = selectedConfigurations.flatMap { xctestrun.dependentProductPaths(config: $0) }
        var unrepresentable: [String] = []
        // Containment is decided on CANONICAL paths (symlinks resolved, ".." collapsed):
        // a dependent entry like "__TESTROOT__/../secret" must be rejected, never
        // silently packaged from outside the build root.
        let canonicalRoot = URL(fileURLWithPath: testRootPath).resolvingSymlinksInPath().standardizedFileURL.path
        let filesToZip = Set(
            dependentPaths.compactMap { path -> String? in
                var path = path
                if path.contains("-Runner.app") {
                    path = path.components(separatedBy: "-Runner.app").dropLast().joined() + "-Runner.app"
                }
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                guard canonical.hasPrefix(canonicalRoot + "/") else {
                    unrepresentable.append(path)
                    return nil
                }
                return String(canonical.dropFirst(canonicalRoot.count + 1))
            }
        )
        // A product outside __TESTROOT__ cannot be packaged relative to it — failing
        // here beats a cryptic zip error (or a silently absent binary on the node).
        guard unrepresentable.isEmpty else {
            throw XCTestRunError(
                "dependent products outside the xctestrun's directory cannot be packaged:\n"
                + unrepresentable.map { "  - \($0)" }.joined(separator: "\n")
            )
        }
        guard !filesToZip.isEmpty else {
            throw XCTestRunError("the xctestrun lists no dependent products to package")
        }
        log?.message(verboseMsg: "Zipping dependent products:\n\t- " + filesToZip.sorted().joined(separator: "\n\t- "))

        let compressionLevel = config.transferCompressionLevel ?? 0
        let zipPath = "\(workspace.workPath)/build.zip"
        let zipStart = dependencies.now()
        // "--" terminates options: a product name starting with "-" can never be
        // parsed as a zip flag.
        try await dependencies.localShell.runChecked(
            "/usr/bin/zip",
            ["-r", "-X", "-q", "-\(compressionLevel)", zipPath, "--"] + filesToZip.sorted(),
            currentDirectory: testRootPath
        )
        let zipSeconds = dependencies.now() - zipStart
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: zipPath)[.size] as? Int64) ?? nil
        let sizeMB = sizeBytes.map { Double($0) / 1_048_576 } ?? 0
        log?.message(verboseMsg: String(format: "Build zip: %@ (%.1f MB, level %d, %.1fs)", zipPath, sizeMB, compressionLevel, zipSeconds))
        return zipPath
    }

    // MARK: - Reports

    private func writeReports(snapshot: TestCasesSnapshot, context: ReportContext) throws {
        let junitURL = URL(fileURLWithPath: "\(workspace.stagingPath)/final_result.xml")
        let jsonURL = URL(fileURLWithPath: "\(workspace.stagingPath)/final_result.json")
        try JSONReport.generate(tests: snapshot, context: context).write(to: jsonURL)
        try JUnit().generate(tests: snapshot, hostname: context.hostname).write(to: junitURL, atomically: true, encoding: .utf8)

        let summaryText = """
        Total Tests: \(snapshot.count)
        Passed: \(snapshot.passed.count) tests
        Failed: \(snapshot.failed.count) tests
        Skipped: \(snapshot.skipped.count) tests
        Unexecuted: \(snapshot.unexecuted.count) tests
        Rerun: \(snapshot.rerun.count) tests
        """
        try summaryText.write(
            toFile: "\(workspace.stagingPath)/final_result.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    private func printSummary(snapshot: TestCasesSnapshot, duration: Double) {
        // Quiet mode (e.g. --events-stdout) owns stdout — not even blank separators.
        guard log?.quiet != true else { return }
        print()
        log?.message("####################################\n")
        log?.message("Total Tests: \(snapshot.count)")
        log?.message("Passed: \(snapshot.passed.count) tests")
        log?.message("Rerun: \(snapshot.rerun.count) tests")
        snapshot.rerun.forEach { log?.warning(before: "\t", "\($0.name) - \($0.launchCounter - 1) times") }
        log?.message("Skipped: \(snapshot.skipped.count) tests")
        snapshot.skipped.forEach { log?.skipped(before: "\t", $0.name) }
        log?.message("Failed: \(snapshot.failed.count) tests")
        snapshot.failed.forEach { log?.failed(before: "\t", $0.name) }
        log?.message("Unexecuted: \(snapshot.unexecuted.count) tests")
        snapshot.unexecuted.forEach { log?.failed(before: "\t", $0.name) }
        log?.message("Done: in \(String(format: "%.3f", duration)) seconds")
        print()
        log?.message("####################################")
    }
}
