import XCTest
@testable import SiftLib

final class ConfigValidationTests: XCTestCase {

    private func makeConfigJSON(
        output: String = "/tmp/sift-out",
        deployment: String = "/tmp/sift-deploy",
        bucket: Int = 4,
        rerun: Int = 1,
        port: Int = 22,
        udids: String = #""simulators": ["ABC-123"]"#
    ) -> Data {
        """
        {
            "xctestrunPath": "/tmp/some.xctestrun",
            "outputDirectoryPath": "\(output)",
            "rerunFailedTest": \(rerun),
            "testsBucket": \(bucket),
            "nodes": [{
                "name": "n1",
                "host": "127.0.0.1",
                "port": \(port),
                "username": "u",
                "deploymentPath": "\(deployment)",
                "UDID": { \(udids) },
                "xcodePath": "/Applications/Xcode.app"
            }]
        }
        """.data(using: .utf8)!
    }

    func testValidConfigPasses() throws {
        XCTAssertNoThrow(try Config(data: makeConfigJSON()))
    }

    func testEmptyOutputPathRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(output: ""))) { error in
            XCTAssertTrue("\(error)".contains("outputDirectoryPath"))
        }
    }

    func testRelativeDeploymentPathRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(deployment: "relative/path")))
    }

    func testRootPathRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(output: "/")))
    }

    func testZeroBucketRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(bucket: 0)))
    }

    func testNegativeRerunRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(rerun: -1)))
    }

    func testInvalidPortRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(port: 0)))
    }

    func testNodeWithoutUDIDsRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(udids: #""simulators": []"#)))
    }

    func testEnvSubstitutionInsideStringValues() throws {
        setenv("SIFT_TEST_SUB", "substituted-value", 1)
        defer { unsetenv("SIFT_TEST_SUB") }
        let json = #"{"key": "prefix-${SIFT_TEST_SUB}-suffix", "nested": {"inner": "${SIFT_TEST_SUB}"}}"#.data(using: .utf8)!
        let result = try Config.substituteEnvironmentVariables(inJSON: json)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertEqual(object["key"] as? String, "prefix-substituted-value-suffix")
        XCTAssertEqual((object["nested"] as? [String: Any])?["inner"] as? String, "substituted-value")
    }

    func testUnresolvedEnvVariableIsError() {
        unsetenv("SIFT_DEFINITELY_UNSET_VAR")
        let json = #"{"key": "${SIFT_DEFINITELY_UNSET_VAR}"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try Config.substituteEnvironmentVariables(inJSON: json)) { error in
            XCTAssertTrue("\(error)".contains("SIFT_DEFINITELY_UNSET_VAR"))
        }
    }

    func testEnvValueWithQuotesCannotCorruptJSON() throws {
        setenv("SIFT_TEST_EVIL", #"va"lue with 'quotes' and \backslash"#, 1)
        defer { unsetenv("SIFT_TEST_EVIL") }
        let json = #"{"key": "${SIFT_TEST_EVIL}"}"#.data(using: .utf8)!
        let result = try Config.substituteEnvironmentVariables(inJSON: json)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertEqual(object["key"] as? String, #"va"lue with 'quotes' and \backslash"#)
    }
}
