import Foundation

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

    public init(
        config: Config,
        tests: [String]? = nil,
        allowEmptyTests: Bool = false,
        discoveryBackend: DiscoveryBackend = .enumeration,
        listSelectors: (only: [String], skip: [String])? = nil,
        log: Logging?
    ) {
        self.config = config
        self.xctestrunPath = config.xctestrunPath
        self.workspace = RunWorkspace(outputDirectoryPath: config.outputDirectoryPath)
        self.discovery = TestDiscovery(log: log)
        self.discoveryBackend = discoveryBackend
        self.listSelectors = listSelectors
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
            var tests = try await discovery.tests(
                xctestrun: xctestrun,
                configuration: configuration,
                backend: discoveryBackend
            )
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
        let startTime = Date.timeIntervalSinceReferenceDate

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
                log?.warning("No tests to execute (--allow-empty-tests set) — exiting cleanly")
                return RunOutcome(
                    snapshot: TestCasesSnapshot(cases: []),
                    duration: 0,
                    mergedResultPath: nil,
                    reportsWritten: false,
                    emptyRunAllowed: true
                )
            }
            throw XCTestRunError("No tests were discovered for execution. If an empty test list is expected, pass --allow-empty-tests.")
        }

        log?.message("Total tests for execution: \(unitsForRun.count)")
        // Serialize runs sharing this output directory; the lock dies with the process.
        let lock = try workspace.acquireLock()
        defer { lock.release() }
        try workspace.prepareLocal()
        defer { workspace.cleanupLocal() }

        let buildZipPath = try await zipBuild()

        let scheduler = TestScheduler(
            units: unitsForRun,
            rerunLimit: config.rerunFailedTest,
            infrastructureRetryLimit: 1,
            log: log
        )
        let collector = ResultCollector(workspace: workspace, log: log)
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
                sshFactory: { config in
                    SSH(
                        host: config.host,
                        port: config.port,
                        arch: config.arch,
                        hostKeyVerification: config.hostKeyVerification ?? .acceptNew
                    )
                },
                health: health,
                log: log
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask { await node.start() }
            }
        }
        // All workers exited — release anything still waiting (e.g. all executors dead).
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        let duration = Date.timeIntervalSinceReferenceDate - startTime

        var mergedPath: String?
        do {
            mergedPath = try await collector.mergeAll()
        } catch {
            log?.error("Result merge FAILED: \(error)")
            throw XCTestRunError("xcresult merge failed: \(error)")
        }

        try writeReports(snapshot: snapshot, duration: duration)
        // Everything was staged under the run directory; one atomic rename makes it
        // `final/` — the previous final survives any failure before this point.
        let publishedPath = try workspace.publish()
        printSummary(snapshot: snapshot, duration: duration)

        let healthEvents = await health.all()
        if !healthEvents.isEmpty {
            log?.warning("Infrastructure health (\(healthEvents.count) event(s)):")
            for event in healthEvents {
                log?.warning(before: "\t", "[\(event.kind.rawValue)] \(event.source): \(event.detail)")
            }
        }

        return RunOutcome(
            snapshot: snapshot,
            duration: duration,
            mergedResultPath: mergedPath.map { _ in "\(publishedPath)/final_result.xcresult" },
            reportsWritten: true,
            healthEvents: healthEvents
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
        let filesToZip = Set(
            dependentPaths.map { path -> String in
                var path = path
                if path.contains("-Runner.app") {
                    path = path.components(separatedBy: "-Runner.app").dropLast().joined() + "-Runner.app"
                }
                return path.replacingOccurrences(of: testRootPath + "/", with: "")
            }
        )
        log?.message(verboseMsg: "Zipping dependent products:\n\t- " + filesToZip.sorted().joined(separator: "\n\t- "))

        let zipPath = "\(workspace.workPath)/build.zip"
        try await Run().runChecked(
            "/usr/bin/zip",
            ["-r", "-X", "-q", "-0", zipPath] + filesToZip.sorted(),
            currentDirectory: testRootPath
        )
        log?.message(verboseMsg: "Build zip: \(zipPath)")
        return zipPath
    }

    // MARK: - Reports

    private func writeReports(snapshot: TestCasesSnapshot, duration: Double) throws {
        let junitURL = URL(fileURLWithPath: "\(workspace.stagingPath)/final_result.xml")
        let jsonURL = URL(fileURLWithPath: "\(workspace.stagingPath)/final_result.json")
        try JSONReport.generate(tests: snapshot, duration: duration).write(to: jsonURL)
        try JUnit().generate(tests: snapshot).write(to: junitURL, atomically: true, encoding: .utf8)

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
