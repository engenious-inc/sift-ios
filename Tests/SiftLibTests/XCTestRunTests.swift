import XCTest
@testable import SiftLib

final class XCTestRunTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw XCTSkip("fixture \(name) missing")
        }
        return url.path
    }

    func testV2ParsesAndQueriesRealBulkFixture() throws {
        let path = try fixture("v2-sim.xctestrun")
        let xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        XCTAssertTrue(xctestrun is XCTestRunV2)
        let bundles = xctestrun.testBundleExecPaths(config: nil)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].target, "BulkTest")
        XCTAssertTrue(bundles[0].path.contains("BulkTest.xctest/BulkTest"), "iOS bundle exec path: \(bundles[0].path)")
        XCTAssertFalse(xctestrun.dependentProductPaths(config: nil).isEmpty)
    }

    func testV2MacBundleExecPathUsesContentsMacOS() throws {
        let path = try fixture("v2-mac.xctestrun")
        let xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        let bundles = xctestrun.testBundleExecPaths(config: nil)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertTrue(bundles[0].path.hasSuffix("BulkTest.xctest/Contents/MacOS/BulkTest"), bundles[0].path)
    }

    func testV2RoundTripPreservesUnmodeledKeys() throws {
        let path = try fixture("v2-sim.xctestrun")
        var xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        xctestrun.addEnvironmentVariables(["SIFT_INJECTED": "yes"])
        xctestrun.add(timeout: 600)
        let data = try xctestrun.data()

        let root = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        // Unmodeled root key survives.
        XCTAssertEqual(root["SiftUnmodeledKey"] as? String, "keep-me")
        let configurations = root["TestConfigurations"] as! [[String: Any]]
        let target = (configurations[0]["TestTargets"] as! [[String: Any]])[0]
        // Unmodeled target key survives.
        XCTAssertEqual(target["SiftUnmodeledTargetKey"] as? String, "target-keep")
        // Mutations applied — including creating a missing EnvironmentVariables dict.
        let environment = target["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(environment?["SIFT_INJECTED"], "yes")
        XCTAssertEqual(target["DefaultTestExecutionTimeAllowance"] as? Int, 600)
        XCTAssertEqual(target["MaximumTestExecutionTimeAllowance"] as? Int, 600)
        XCTAssertEqual(target["TestTimeoutsEnabled"] as? Bool, true)
        // CodeCoverageBuildableInfos and other unmodeled structures survive.
        XCTAssertNotNil(root["CodeCoverageBuildableInfos"])
        XCTAssertNotNil(root["ContainerInfo"])
    }

    func testV2SemanticTreeEquivalenceOutsideMutatedKeys() throws {
        let path = try fixture("v2-sim.xctestrun")
        let original = try PropertyListSerialization.propertyList(
            from: FileManager.default.contents(atPath: path)!, format: nil
        ) as! NSDictionary

        let xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        // No mutations: round trip must be semantically identical.
        let reserialized = try PropertyListSerialization.propertyList(from: xctestrun.data(), format: nil) as! NSDictionary
        XCTAssertEqual(original, reserialized)
    }

    func testV2UnknownConfigurationNameThrows() throws {
        let path = try fixture("v2-sim.xctestrun")
        let xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        XCTAssertThrowsError(try xctestrun.validate(configurationName: "NoSuchConfig"))
        XCTAssertNoThrow(try xctestrun.validate(configurationName: "Test Scheme Action"))
        XCTAssertNoThrow(try xctestrun.validate(configurationName: nil))
    }

    func testV1ParsesQueriesAndMutates() throws {
        let path = try fixture("v1.xctestrun")
        var xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        XCTAssertTrue(xctestrun is XCTestRunV1)

        let bundles = xctestrun.testBundleExecPaths(config: nil)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].target, "MyUITests")
        XCTAssertTrue(bundles[0].path.contains("MyUITests.xctest/MyUITests"))

        XCTAssertEqual(xctestrun.skipTestIdentifiers(config: nil)["MyUITests"], ["MyUITests/testSkipped"])
        XCTAssertEqual(xctestrun.dependentProductPaths(config: nil).count, 2)

        // V1 now supports env + timeout injection (was a silent no-op before).
        xctestrun.addEnvironmentVariables(["K": "V"])
        xctestrun.add(timeout: 120)
        let root = try PropertyListSerialization.propertyList(from: xctestrun.data(), format: nil) as! [String: Any]
        let module = root["MyUITests"] as! [String: Any]
        XCTAssertEqual((module["EnvironmentVariables"] as? [String: String])?["K"], "V")
        XCTAssertEqual(module["DefaultTestExecutionTimeAllowance"] as? Int, 120)
        XCTAssertEqual(module["UnmodeledV1Key"] as? String, "v1-keep")
    }

    func testV1RejectsConfigurationSelectors() throws {
        let path = try fixture("v1.xctestrun")
        let xctestrun = try XCTestRunFactory.create(path: path, log: nil)
        XCTAssertThrowsError(try xctestrun.validate(configurationName: "Any"))
    }

    func testMalformedFileThrowsInsteadOfSilentFallback() {
        XCTAssertThrowsError(try XCTestRunFactory.create(path: "/nonexistent/file.xctestrun", log: nil))
    }
}
