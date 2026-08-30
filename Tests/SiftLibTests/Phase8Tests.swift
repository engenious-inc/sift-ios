import XCTest
@testable import SiftLib

/// Phase 8 surfaces: local transport config, provisioning validation, suite-less
/// identifiers (Swift Testing free functions), and the event stream.
final class Phase8Tests: XCTestCase {

    func testLocalTransportNeedsNoHostOrCredentials() throws {
        let json = """
        {"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "here", "transport": "local", "deploymentPath": "/tmp/d",
                    "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """.data(using: .utf8)!
        XCTAssertNoThrow(try Config(data: json))
    }

    func testLocalTransportRejectsCredentials() {
        let json = """
        {"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "here", "transport": "local", "password": "p", "deploymentPath": "/tmp/d",
                    "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("local transport takes no credentials"), "\(error)")
        }
    }

    func testSSHTransportStillRequiresHost() {
        let json = """
        {"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "n", "deploymentPath": "/tmp/d",
                    "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("host is required"), "\(error)")
        }
    }

    func testProvisioningAloneSatisfiesExecutorRequirementAndIsValidated() throws {
        func config(count: Int, deviceType: String = "iPhone 17") -> Data {
            """
            {"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
             "rerunFailedTest": 0, "testsBucket": 1,
             "nodes": [{"name": "here", "transport": "local", "deploymentPath": "/tmp/d",
                        "UDID": {}, "provisionSimulators": {"deviceType": "\(deviceType)", "count": \(count)},
                        "xcodePath": "/Applications/Xcode.app"}]}
            """.data(using: .utf8)!
        }
        XCTAssertNoThrow(try Config(data: config(count: 2)))
        XCTAssertThrowsError(try Config(data: config(count: 0)))
        XCTAssertThrowsError(try Config(data: config(count: 2, deviceType: " ")))
    }

    func testSuiteLessIdentifiersRoundTrip() throws {
        // Top-level Swift Testing function: "Bundle/test()" — 2 components.
        let scheduled = ScheduledTest(configurationName: nil, targetKey: "T", productModuleName: "T",
                                      bundleName: "SwiftTestingFixtures", classPath: "", method: "modernAdditionWorks()")
        XCTAssertEqual(scheduled.id, "SwiftTestingFixtures/modernAdditionWorks()")
        // Selector expansion reaches it.
        let expanded = try TestSelector.expand(rawSelectors: ["SwiftTestingFixtures/modernAdditionWorks()"], against: [scheduled])
        XCTAssertEqual(expanded, [scheduled])
        // Enumeration parsing: paren-less ObjC + suite-less rows both parse; a
        // bundle-only row is a FAILED expansion and must throw.
        let document = try JSONDecoder().decode(TestDiscovery.EnumerationDocument.self, from: Data("""
        {"errors": [], "values": [{"disabledTests": [], "enabledTests": [
            {"identifier": "B/LegacyObjC/testNoParens"},
            {"identifier": "B/freeFunction()"}
        ]}]}
        """.utf8))
        let descriptors = [TestBundleDescriptor(targetKey: "B", productModuleName: "B", bundleName: "B", executablePath: "/dev/null")]
        let tests = try TestDiscovery.scheduledTests(fromEnumeration: document, configuration: nil, descriptors: descriptors, log: nil)
        XCTAssertEqual(tests.map(\.id).sorted(), ["B/LegacyObjC/testNoParens()", "B/freeFunction()"])

        let unexpanded = try JSONDecoder().decode(TestDiscovery.EnumerationDocument.self, from: Data("""
        {"errors": [], "values": [{"disabledTests": [], "enabledTests": [{"identifier": "BrokenBundle"}]}]}
        """.utf8))
        XCTAssertThrowsError(try TestDiscovery.scheduledTests(fromEnumeration: unexpanded, configuration: nil, descriptors: descriptors, log: nil))
    }

    /// XCTest and Swift Testing share the bundle/class/method namespace: a
    /// COLLIDING identifier (same bundle, class name, method) cannot be selected,
    /// retried, or reported apart — discovery must reject it loudly, never
    /// silently dedupe one side away.
    func testCollidingIdentifiersAcrossFrameworksAreAnError() throws {
        let document = try JSONDecoder().decode(TestDiscovery.EnumerationDocument.self, from: Data("""
        {"errors": [], "values": [{"disabledTests": [], "enabledTests": [
            {"identifier": "B/Shared/testSame()"},
            {"identifier": "B/Shared/testSame"}
        ]}]}
        """.utf8))
        let descriptors = [TestBundleDescriptor(targetKey: "B", productModuleName: "B", bundleName: "B", executablePath: "/dev/null")]
        XCTAssertThrowsError(try TestDiscovery.scheduledTests(fromEnumeration: document, configuration: nil, descriptors: descriptors, log: nil)) { error in
            XCTAssertTrue("\(error)".contains("B/Shared/testSame()"), "\(error)")
        }
    }

    /// RECORDED Xcode 16-line fixture (`xcresulttool get test-results tests` over a
    /// real Swift Testing run): a suite-less top-level `@Test` function and a
    /// `@Suite` case must both parse into canonical bundle-prefixed identifiers
    /// through the PRODUCTION traversal.
    func testSwiftTestingXCResultFixtureParses() throws {
        guard let url = Bundle.module.url(forResource: "Fixtures/test-results-swift-testing", withExtension: "json") else {
            return XCTFail("missing recorded fixture test-results-swift-testing.json")
        }
        let outcomes = try XCResultTool.outcomes(fromTestResultsJSON: Data(contentsOf: url))
        XCTAssertEqual(outcomes.map(\.test).sorted(), [
            "SwiftTestingFixtures/ModernSuite/suiteCaseWorks()",
            "SwiftTestingFixtures/modernAdditionWorks()",
        ])
        XCTAssertTrue(outcomes.allSatisfy { $0.kind == .pass })
    }

    func testEventBusWritesValidNDJSON() async throws {
        let path = NSTemporaryDirectory() + "sift-events-\(UUID().uuidString).ndjson"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let bus = EventBus(ndjsonPath: path)
        await bus.emit("runStarted", ["tests": "3"])
        await bus.emit("testFinished", ["test": "B/C/t()", "outcome": "passed"])
        await bus.finish()

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let event = try decoder.decode(RunEvent.self, from: Data(line.utf8))
            XCTAssertEqual(event.version, 1)
        }
        XCTAssertEqual(try decoder.decode(RunEvent.self, from: Data(lines[0].utf8)).kind, "runStarted")
    }
}
