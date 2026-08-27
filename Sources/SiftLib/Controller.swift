import Foundation

public struct Controller {
    private let config: Config
    private let xctestrunPath: String
    private let workspace: RunWorkspace
    private let discovery: TestDiscovery
    private let log: Logging?

    public private(set) var bundleTests: [String] = []
    private var requestedTests: [String]

    private let allowEmptyTests: Bool

    public init(
        config: Config,
        tests: [String]? = nil,
        allowEmptyTests: Bool = false,
        log: Logging?
    ) {
        self.config = config
        self.xctestrunPath = config.xctestrunPath
        self.workspace = RunWorkspace(outputDirectoryPath: config.outputDirectoryPath)
        self.discovery = TestDiscovery(log: log)
        self.requestedTests = tests ?? []
        self.allowEmptyTests = allowEmptyTests
        self.log = log
    }

    // MARK: - Discovery (side-effect-free; used by both `list` and `run`)

    public mutating func discoverTests() async throws -> [String] {
        let xctestrun = try XCTestRunFactory.create(path: xctestrunPath, log: log)
        try xctestrun.validate(configurationName: config.onlyTestConfiguration)

        var tests = try await discovery.tests(xctestrun: xctestrun, configuration: config.onlyTestConfiguration)

        let only = xctestrun.onlyTestIdentifiers(config: config.onlyTestConfiguration)
        if !only.isEmpty {
            log?.message(verboseMsg: "OnlyTestIdentifiers:\n\(only)")
            tests = tests.filter { test in
                let moduleName = test.components(separatedBy: "/").first ?? ""
                guard let identifiers = only[moduleName.replacingOccurrences(of: " ", with: "_")], !identifiers.isEmpty else {
                    return true
                }
                return identifiers.contains { identifierMatches($0, test: test) }
            }
        }
        let skip = xctestrun.skipTestIdentifiers(config: config.onlyTestConfiguration)
        if !skip.isEmpty {
            log?.message(verboseMsg: "SkipTestIdentifiers:\n\(skip)")
            tests = tests.filter { test in
                let moduleName = test.components(separatedBy: "/").first ?? ""
                guard let identifiers = skip[moduleName.replacingOccurrences(of: " ", with: "_")] else { return true }
                return !identifiers.contains { identifierMatches($0, test: test) }
            }
        }

        self.bundleTests = tests
        return tests
    }

    /// True when `identifier` ("Class" or "Class/test") selects `test` ("Module/Class/test()").
    private func identifierMatches(_ identifier: String, test: String) -> Bool {
        let testComponents = test.components(separatedBy: "/").dropFirst().map { $0.replacingOccurrences(of: "()", with: "") }
        let identifierComponents = identifier.components(separatedBy: "/").map { $0.replacingOccurrences(of: "()", with: "") }
        guard identifierComponents.count <= testComponents.count else { return false }
        return zip(identifierComponents, testComponents).allSatisfy { $0 == $1 }
    }

    // MARK: - Run

    public mutating func run() async throws -> RunOutcome {
        let startTime = Date.timeIntervalSinceReferenceDate

        let discovered = try await discoverTests()
        let testsForRun = requestedTests.isEmpty ? discovered : TestName.canonicalList(requestedTests)

        guard !testsForRun.isEmpty else {
            if allowEmptyTests {
                log?.warning("No tests to execute (--allow-empty-tests set) — exiting cleanly")
                return RunOutcome(
                    snapshot: TestCasesSnapshot(cases: []),
                    duration: 0,
                    mergedResultPath: nil,
                    reportsWritten: false
                )
            }
            throw NSError(
                domain: "No tests were discovered for execution. If an empty test list is expected, pass --allow-empty-tests.",
                code: 1
            )
        }

        log?.message("Total tests for execution: \(testsForRun.count)")
        try workspace.prepareLocal()
        defer { workspace.cleanupLocal() }

        let buildZipPath = try await zipBuild()

        let scheduler = TestScheduler(
            tests: testsForRun,
            rerunLimit: config.rerunFailedTest,
            infrastructureRetryLimit: 1,
            log: log
        )
        let collector = ResultCollector(workspace: workspace, log: log)

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
            throw NSError(domain: "xcresult merge failed: \(error)", code: 1)
        }

        try writeReports(snapshot: snapshot, duration: duration)
        printSummary(snapshot: snapshot, duration: duration)

        return RunOutcome(
            snapshot: snapshot,
            duration: duration,
            mergedResultPath: mergedPath,
            reportsWritten: true
        )
    }

    // MARK: - Build packaging

    private func zipBuild() async throws -> String {
        let xctestrun = try XCTestRunFactory.create(path: xctestrunPath, log: log)
        let testRootPath = xctestrun.testRootPath
        var filesToZip = Set(
            xctestrun.dependentProductPaths(config: config.onlyTestConfiguration).map { path -> String in
                var path = path
                if path.contains("-Runner.app") {
                    path = path.components(separatedBy: "-Runner.app").dropLast().joined() + "-Runner.app"
                }
                return path.replacingOccurrences(of: testRootPath + "/", with: "")
            }
        )
        filesToZip = Set(filesToZip.map { $0.hasPrefix("/") ? $0 : $0 })
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
        let junitURL = URL(fileURLWithPath: "\(workspace.finalPath)/final_result.xml")
        let jsonURL = URL(fileURLWithPath: "\(workspace.finalPath)/final_result.json")
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
            toFile: "\(workspace.finalPath)/final_result.txt",
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
