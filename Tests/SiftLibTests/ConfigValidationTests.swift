import XCTest
@testable import SiftLib

private extension Data {
    func replacingFirst(of needle: String, with replacement: String) -> Data {
        var text = String(decoding: self, as: UTF8.self)
        if let range = text.range(of: needle) {
            text.replaceSubrange(range, with: replacement)
        }
        return Data(text.utf8)
    }
}

final class ConfigValidationTests: XCTestCase {

    private func makeConfigJSON(
        output: String = "/tmp/sift-out",
        deployment: String = "/tmp/sift-deploy",
        bucket: Int = 4,
        rerun: Int = 1,
        port: Int = 22,
        host: String = "127.0.0.1",
        name: String = "n1",
        udids: String = #""simulators": ["ABC-123"]"#
    ) -> Data {
        """
        {
            "xctestrunPath": "/tmp/some.xctestrun",
            "outputDirectoryPath": "\(output)",
            "rerunFailedTest": \(rerun),
            "testsBucket": \(bucket),
            "nodes": [{
                "name": "\(name)",
                "host": "\(host)",
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

    /// A copied ssh entry whose transport was flipped to "local" must be rejected,
    /// not silently run the whole load on the controller machine.
    func testLocalNodeWithSSHFieldsRejected() {
        let json = Data("""
        {"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/o",
         "rerunFailedTest": 1, "testsBucket": 1,
         "nodes": [{"name": "here", "transport": "local", "host": "ci-mac-7", "deploymentPath": "/tmp/d",
                    "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """.utf8)
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("local transport takes no host"), "\(error)")
        }
    }

    /// `.whitespaces` misses \n and \r; a templated "10.0.0.5\n" must fail here,
    /// not as a confusing DNS error inside libssh2.
    func testHostWithNewlineOrTabRejected() {
        for badHost in [#"10.0.0.5\n"#, #"build\thost"#] {
            XCTAssertThrowsError(try Config(data: makeConfigJSON(host: badHost))) { error in
                XCTAssertTrue("\(error)".contains("host contains whitespace"), "\(error)")
            }
        }
    }

    func testNewlineOnlyNodeNameRejected() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(name: #"\n"#))) { error in
            XCTAssertTrue("\(error)".contains("name must not be empty"), "\(error)")
        }
    }

    func testUsernameWithWhitespaceRejected() {
        let json = makeConfigJSON().replacingFirst(of: #""username": "u""#, with: #""username": "u ser""#)
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("username contains whitespace"), "\(error)")
        }
    }

    /// An empty or padded UDID must fail preflight instead of surfacing later as a
    /// destination-resolution error on the node.
    func testEmptyOrPaddedUDIDRejected() {
        for badUDIDs in [#""simulators": [""]"#, #""simulators": [" ABC-123"]"#] {
            XCTAssertThrowsError(try Config(data: makeConfigJSON(udids: badUDIDs))) { error in
                XCTAssertTrue("\(error)".contains("invalid UDID"), "\(error)")
            }
        }
    }

    /// `sift list` works from a MINIMAL discovery config: only the xctestrun path.
    /// The same document must still be rejected for `run` — with validation
    /// messages, not a JSON missing-key error.
    func testMinimalDiscoveryConfigListsButCannotRun() throws {
        let minimal = Data(#"{"xctestrunPath": "/tmp/some.xctestrun"}"#.utf8)
        XCTAssertNoThrow(try Config(data: minimal, role: .list))
        XCTAssertThrowsError(try Config(data: minimal, role: .run)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("outputDirectoryPath"), text)
            XCTAssertTrue(text.contains("testsBucket"), text)
            XCTAssertTrue(text.contains("node"), text)
        }
    }

    func testOrphanedPublicKeyOrPassphraseRejected() {
        let publicKeyOnly = makeConfigJSON().replacingFirst(
            of: #""username": "u","#,
            with: #""username": "u", "publicKey": "/tmp/k.pub","#
        )
        XCTAssertThrowsError(try Config(data: publicKeyOnly)) { error in
            XCTAssertTrue("\(error)".contains("publicKey"), "\(error)")
        }
        let passphraseOnly = makeConfigJSON().replacingFirst(
            of: #""username": "u","#,
            with: #""username": "u", "passphrase": "secret","#
        )
        XCTAssertThrowsError(try Config(data: passphraseOnly)) { error in
            XCTAssertTrue("\(error)".contains("passphrase"), "\(error)")
        }
    }

    /// An xctestrun living under the output directory would be consumed and then
    /// DELETED by publication — rejected at preflight.
    func testXctestrunInsideOutputDirectoryRejected() throws {
        let root = NSTemporaryDirectory() + "sift-overlap-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/final", withIntermediateDirectories: true)
        let artifact = "\(root)/final/t.xctestrun"
        FileManager.default.createFile(atPath: artifact, contents: Data("plist".utf8))
        let json = """
        {"xctestrunPath": "\(artifact)", "outputDirectoryPath": "\(root)",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "here", "transport": "local", "deploymentPath": "/tmp/d",
                    "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]}
        """.data(using: .utf8)!
        let config = try Config(data: json)
        XCTAssertThrowsError(try config.validateRuntimeFiles()) { error in
            XCTAssertTrue("\(error)".contains("inside outputDirectoryPath"), "\(error)")
        }
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

    func testDuplicateNodeIdentitiesRejected() {
        let json = """
        {
            "xctestrunPath": "/tmp/some.xctestrun",
            "outputDirectoryPath": "/tmp/sift-out",
            "rerunFailedTest": 0,
            "testsBucket": 1,
            "nodes": [
                {"name": "n1", "host": "10.0.0.1", "port": 22, "username": "u",
                 "deploymentPath": "/tmp/d", "UDID": {"simulators": ["AAA"]}, "xcodePath": "/Applications/Xcode.app"},
                {"name": "n1", "host": "10.0.0.1", "port": 22, "username": "u",
                 "deploymentPath": "/tmp/d", "UDID": {"simulators": ["AAA"]}, "xcodePath": "/Applications/Xcode.app"}
            ]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("duplicate node name"), message)
            XCTAssertTrue(message.contains("duplicate endpoint"), message)
            XCTAssertTrue(message.contains("duplicate UDID"), message)
        }
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

    func testWhitespacePathRejectedNotSilentlyTrimmed() {
        XCTAssertThrowsError(try Config(data: makeConfigJSON(output: " /tmp/sift-out "))) { error in
            XCTAssertTrue("\(error)".contains("whitespace"), "\(error)")
        }
    }

    func testPasswordPlusPrivateKeyRejected() {
        let json = """
        {
            "xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
            "rerunFailedTest": 0, "testsBucket": 1,
            "nodes": [{"name": "n1", "host": "127.0.0.1", "port": 22, "username": "u",
                       "password": "p", "privateKey": "/tmp/id", "deploymentPath": "/tmp/d",
                       "UDID": {"simulators": ["A"]}, "xcodePath": "/Applications/Xcode.app"}]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("exactly one"), "\(error)")
        }
    }

    func testInvalidEnvironmentVariableNameRejected() {
        let json = """
        {
            "xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
            "rerunFailedTest": 0, "testsBucket": 1,
            "nodes": [{"name": "n1", "host": "127.0.0.1", "port": 22, "username": "u",
                       "deploymentPath": "/tmp/d", "UDID": {"simulators": ["A"]},
                       "environmentVariables": {"BAD KEY; rm -rf ~": "v"},
                       "xcodePath": "/Applications/Xcode.app"}]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json)) { error in
            XCTAssertTrue("\(error)".contains("invalid environment variable name"), "\(error)")
        }
    }

    func testOnlyEqualsSkipConfigurationRejected() {
        let json = """
        {
            "xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/tmp/sift-out",
            "rerunFailedTest": 0, "testsBucket": 1,
            "onlyTestConfiguration": "C1", "skipTestConfiguration": "C1",
            "nodes": [{"name": "n1", "host": "127.0.0.1", "port": 22, "username": "u",
                       "deploymentPath": "/tmp/d", "UDID": {"simulators": ["A"]},
                       "xcodePath": "/Applications/Xcode.app"}]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Config(data: json))
    }

    func testListRoleSkipsNodeValidation() throws {
        let json = #"{"xctestrunPath": "/tmp/some.xctestrun", "outputDirectoryPath": "/x", "rerunFailedTest": 0, "testsBucket": 1, "nodes": []}"#.data(using: .utf8)!
        XCTAssertNoThrow(try Config(data: json, role: .list))
        XCTAssertThrowsError(try Config(data: json, role: .run))
    }

    func testDollarEscapeProducesLiteralPlaceholder() throws {
        let json = #"{"key": "$${NAME} and $${OTHER}"}"#.data(using: .utf8)!
        let result = try Config.substituteEnvironmentVariables(inJSON: json)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertEqual(object["key"] as? String, "${NAME} and ${OTHER}")
    }

    func testUnterminatedPlaceholderIsError() {
        let json = #"{"key": "broken ${NAME"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try Config.substituteEnvironmentVariables(inJSON: json)) { error in
            XCTAssertTrue("\(error)".contains("unterminated"), "\(error)")
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
