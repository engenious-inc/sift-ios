import XCTest
@testable import SiftLib

final class UtilityTests: XCTestCase {

    // MARK: - Shell quoting

    func testShellQuotingNeutralizesMetacharacters() async throws {
        let hostile = #"$(rm -rf /tmp/nope); `echo hacked` && ' || "quoted""#
        let result = try await Run().run("printf %s \(hostile.shellQuoted)")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, hostile)
    }

    func testShellQuotingHandlesSpacesAndUnicode() async throws {
        let value = "path with spaces/и юникод/emoji 🚀"
        let result = try await Run().run("printf %s \(value.shellQuoted)")
        XCTAssertEqual(result.output, value)
    }

    // MARK: - CommandLineExecutor

    func testChecksNonzeroStatusAndCapturesStderr() async {
        do {
            _ = try await Run().runChecked("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.status, 3)
            XCTAssertTrue(error.stderr.contains("err"))
            XCTAssertTrue(error.stdout.contains("out"))
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testLargeOutputIsNotTruncatedOrReordered() async throws {
        // The historical bug: unordered detached tasks truncated/reordered pipe data.
        let result = try await Run().runChecked("/bin/sh", ["-c", "for i in $(seq 1 20000); do echo line-$i; done"])
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 20000)
        XCTAssertEqual(lines.first, "line-1")
        XCTAssertEqual(lines.last, "line-20000")
    }

    func testMissingExecutableThrowsInsteadOfCrashing() async {
        do {
            _ = try await Run().runChecked("/no/such/binary", [])
            XCTFail("expected throw")
        } catch {
            // any thrown error is correct; the old launch() raised an uncatchable NSException
        }
    }

    // MARK: - TestName canonicalization

    func testCanonicalization() {
        XCTAssertEqual(TestName.canonical("M/C/testA"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical("M/C/testA()"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical("  M/C/testA()\r"), "M/C/testA()")
        XCTAssertEqual(TestName.canonical(""), "")
    }

    // MARK: - RunWorkspace

    func testWorkspaceCleanupTouchesOnlyRunDirectory() throws {
        let base = NSTemporaryDirectory() + "sift-ws-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A pre-existing user file next to the output directory must survive.
        let bystander = "\(base)/precious-user-file.txt"
        FileManager.default.createFile(atPath: bystander, contents: Data("do not delete".utf8))

        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.workPath))
        FileManager.default.createFile(atPath: "\(workspace.workPath)/scratch.txt", contents: Data())
        workspace.cleanupLocal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.workPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.finalPath))
    }

    // MARK: - XCResult parsing (modern API, fixture recorded from a real Bulk run)

    func testModernTestResultsParsing() throws {
        guard let url = Bundle.module.url(forResource: "Fixtures/test-results-tests", withExtension: "json") else {
            throw XCTSkip("fixture missing")
        }
        let document = try JSONDecoder().decode(XCResultTool.TestResultsDocument.self, from: Data(contentsOf: url))
        XCTAssertFalse(document.testNodes.isEmpty)

        // Reuse the traversal through a tool instance via reflection-free path:
        // walk manually mirroring collectOutcomes contract.
        var outcomes: [TestOutcome] = []
        func walk(_ node: XCResultTool.TestNode, bundle: String?) {
            var bundle = bundle
            if node.nodeType.hasSuffix("test bundle") { bundle = node.name }
            if node.nodeType == "Test Case", let id = node.nodeIdentifier, let bundle {
                let kind: TestOutcome.Kind
                switch node.result {
                case "Passed", "Expected Failure": kind = .pass
                case "Skipped": kind = .skipped
                case "Failed": kind = .failed
                default: kind = .notExecuted
                }
                outcomes.append(TestOutcome(test: TestName.canonical("\(bundle)/\(id)"), kind: kind, duration: node.durationInSeconds ?? 0))
                return
            }
            for child in node.children ?? [] { walk(child, bundle: bundle) }
        }
        for node in document.testNodes { walk(node, bundle: nil) }

        XCTAssertEqual(outcomes.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.test, $0) })
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_1()"]?.kind, .pass)
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_10()"]?.kind, .failed)
        XCTAssertEqual(byName["BulkTest/BulkTest/testExample_13()"]?.kind, .skipped)
        XCTAssertGreaterThan(byName["BulkTest/BulkTest/testExample_1()"]?.duration ?? 0, 0)
    }

    // MARK: - TestDiscovery demangle parsing

    func testDiscoveryAgainstRealBulkBinary() async throws {
        let binary = "/Users/antonprokuda/Repos/Bulk/DerivedData/mac/Build/Products/Debug/BulkTest-Runner.app/Contents/PlugIns/BulkTest.xctest/Contents/MacOS/BulkTest"
        guard FileManager.default.fileExists(atPath: binary) else {
            throw XCTSkip("Bulk build products not present on this machine")
        }
        let tests = try await TestDiscovery().dump(binaryPath: binary, moduleName: "BulkTest")
        XCTAssertEqual(tests.count, 30)
        XCTAssertTrue(tests.contains("BulkTest/BulkTest/testExample_1()"))
        XCTAssertTrue(tests.contains("BulkTest/BulkTest/testExample_30()"))
        XCTAssertFalse(tests.contains { $0.contains("setUpWithError") })
    }
}
