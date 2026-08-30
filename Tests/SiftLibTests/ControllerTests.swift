import XCTest
@testable import SiftLib

/// Phase 7: hermetic end-to-end Controller behavior through the injected
/// dependency seams — no SSH, no xcodebuild, no simulators.
final class ControllerTests: XCTestCase {

    private struct FakeResultParsing: XCResultParsing {
        let outcomes: [TestOutcome]
        let mergeFails: Bool
        func testOutcomes(xcresultPath: String) async throws -> [TestOutcome] { outcomes }
        func merge(inputPaths: [String], outputPath: String) async throws -> Bool {
            if mergeFails {
                throw XCTestRunError("scripted merge failure")
            }
            try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
            return true
        }
    }

    /// Copies the fixture xctestrun into a temp root and creates its dependent
    /// product paths so zipBuild can really zip (tiny) files.
    private func makeEnvironment() throws -> (configJSON: Data, outputBase: String) {
        guard let fixtureURL = Bundle.module.url(forResource: "Fixtures/v2-sim.xctestrun", withExtension: nil) else {
            throw XCTSkip("fixture missing")
        }
        let root = NSTemporaryDirectory() + "sift-controller-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let xctestrunPath = "\(root)/fixture.xctestrun"
        try FileManager.default.copyItem(atPath: fixtureURL.path, toPath: xctestrunPath)
        // Materialize the dependent products the fixture references.
        let xctestrun = try XCTestRunFactory.create(path: xctestrunPath, log: nil)
        for path in xctestrun.dependentProductPaths(config: nil) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path + "/binary", contents: Data("stub".utf8))
        }
        let outputBase = "\(root)/out"
        let config = """
        {"xctestrunPath": "\(xctestrunPath)", "outputDirectoryPath": "\(outputBase)",
         "rerunFailedTest": 0, "testsBucket": 4, "testsExecutionTimeout": 60,
         "nodes": [{"name": "fake-node", "host": "127.0.0.1", "port": 22, "username": "u",
                    "deploymentPath": "\(root)/deploy", "UDID": {"simulators": ["FAKE-UDID-1"]},
                    "xcodePath": "/Applications/Xcode.app"}]}
        """
        return (Data(config.utf8), outputBase)
    }

    private func makeTests() -> [ScheduledTest] {
        (1...4).map {
            ScheduledTest(configurationName: "Test Scheme Action", targetKey: "BulkTest",
                          productModuleName: "BulkTest", bundleName: "BulkTest",
                          classPath: "BulkTest", method: "testExample_\($0)()")
        }
    }

    /// A valid zip whose single entry is a dummy .xcresult directory.
    private func makeResultsZipPayload() throws -> Data {
        let source = NSTemporaryDirectory() + "sift-zip-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(source)/r.xcresult", withIntermediateDirectories: true)
        try "stub".write(toFile: "\(source)/r.xcresult/Info.plist", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: source) }
        let zipPath = "\(source).zip"
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = URL(fileURLWithPath: source)
        zip.arguments = ["-r", "-q", zipPath, "r.xcresult"]
        try zip.run(); zip.waitUntilExit()
        return try Data(contentsOf: URL(fileURLWithPath: zipPath))
    }

    func testAllExecutorsUnavailableStillPublishesReportsAndFails() async throws {
        let (configJSON, outputBase) = try makeEnvironment()
        let config = try Config(data: configJSON)
        let shell = FakeSSHExecutor()
        // The fake simctl listing knows FAKE-UDID-1; make readiness fail by
        // scripting the listing command to error.
        shell.withState { $0.commandFailuresForPrefix["export DEVELOPER_DIR"] = 1 }

        var dependencies = ControllerDependencies()
        dependencies.sshFactory = { _ in shell }
        dependencies.resultTool = FakeResultParsing(outcomes: [], mergeFails: false)
        let tests = makeTests()
        dependencies.testsProvider = { _ in tests }

        var controller = Controller(config: config, dependencies: dependencies, log: nil)
        let outcome = try await controller.run()

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.snapshot.unexecuted.count, 4, "nothing ran — every test unexecuted")
        XCTAssertTrue(outcome.healthEvents.contains { $0.kind == .executorUnavailable })
        XCTAssertTrue(outcome.reportsWritten)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outputBase)/final/final_result.xml"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outputBase)/final/final_result.json"))
    }

    func testMergeFailureStillPublishesReportsAndExitsNonZero() async throws {
        let (configJSON, outputBase) = try makeEnvironment()
        let config = try Config(data: configJSON)
        let shell = FakeSSHExecutor()
        let payload = try makeResultsZipPayload()
        shell.withState {
            $0.pollResults = [65, 65]  // one status per chunk poll (bucket 4 → 1 chunk)
            $0.downloadPayload = payload
        }

        let tests = makeTests()
        let outcomes = tests.map { TestOutcome(test: $0.id, kind: .pass, duration: 1) }
        var dependencies = ControllerDependencies()
        dependencies.sshFactory = { _ in shell }
        dependencies.resultTool = FakeResultParsing(outcomes: outcomes, mergeFails: true)
        dependencies.testsProvider = { _ in tests }

        var controller = Controller(config: config, dependencies: dependencies, log: nil)
        let outcome = try await controller.run()

        XCTAssertEqual(outcome.snapshot.passed.count, 4, "the chunk really ran and passed")
        XCTAssertTrue(outcome.mergeFailed)
        XCTAssertFalse(outcome.succeeded, "a failed merge must fail the run")
        XCTAssertTrue(outcome.healthEvents.contains { $0.kind == .mergeFailed })
        // Reports exist DESPITE the merge failure, and raw bundles are published.
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outputBase)/final/final_result.xml"))
        let json = try Data(contentsOf: URL(fileURLWithPath: "\(outputBase)/final/final_result.json"))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"mergeStatus\" : \"failed\""), "JSON records the merge failure")
        let finalEntries = try FileManager.default.contentsOfDirectory(atPath: "\(outputBase)/final")
        XCTAssertTrue(finalEntries.contains { $0.hasSuffix(".xcresult") && $0 != "final_result.xcresult" },
                      "raw per-chunk bundles are published as evidence: \(finalEntries)")
    }
}
