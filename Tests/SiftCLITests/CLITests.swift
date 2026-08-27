import XCTest

/// Black-box CLI tests: invoke the built `Sift` binary and assert exit codes and
/// output — the contract CI systems depend on.
final class CLITests: XCTestCase {

    private var binaryURL: URL {
        // The test bundle sits in the same build products directory as the CLI.
        Bundle(for: CLITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Sift")
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        // Drain both pipes CONCURRENTLY: sequential readDataToEndOfFile deadlocks
        // once the unread pipe's buffer fills.
        final class DataBox: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let stderrBox = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrBox.get(), encoding: .utf8) ?? ""
        )
    }

    private func requireBinary() throws {
        // The CLI contract suite is meaningless without the CLI: a missing binary is
        // a build problem and must FAIL, not silently skip the whole suite.
        if !FileManager.default.fileExists(atPath: binaryURL.path) {
            XCTFail("Sift binary not present next to the test bundle — the package build must produce it")
        }
    }

    /// Repo-relative fixture path (CLITests are black-box and have no bundle resources).
    private var fixtureXctestrun: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SiftCLITests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("SiftLibTests/Fixtures/v2-sim.xctestrun")
            .path
    }

    private func writeTempConfig(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "sift-cli-test-\(UUID().uuidString).json"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testHelpExitsZero() throws {
        try requireBinary()
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("parallel XCTest execution"))
    }

    func testRunWithInvalidConfigExits64() throws {
        try requireBinary()
        let config = try writeTempConfig(#"{"xctestrunPath": "", "outputDirectoryPath": "/", "rerunFailedTest": -1, "testsBucket": 0, "nodes": []}"#)
        let result = try runCLI(["run", "-c", config])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stdout.contains("Invalid config") || result.stderr.contains("Invalid config"))
    }

    func testListWithInvalidConfigExits64() throws {
        try requireBinary()
        let config = try writeTempConfig(#"{"broken": true}"#)
        let result = try runCLI(["list", "-c", config])
        XCTAssertEqual(result.status, 64)
    }

    func testRunWithMissingConfigFileExits64() throws {
        try requireBinary()
        let result = try runCLI(["run", "-c", "/nonexistent/config.json"])
        XCTAssertEqual(result.status, 64)
    }

    func testNegativeTimeoutIsUsageError() throws {
        try requireBinary()
        let config = try writeTempConfig("{}")
        let result = try runCLI(["run", "-c", config, "--timeout", "-5"])
        // ArgumentParser validation error (64) — never a crash.
        XCTAssertEqual(result.status, 64)
    }

    func testErrorsGoToStderrNotStdout() throws {
        try requireBinary()
        let result = try runCLI(["run", "-c", "/nonexistent/config.json"])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("config"), "diagnostics on stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.isEmpty, "stdout must stay clean for pipelines, got: \(result.stdout)")
    }

    func testMissingXctestrunFileIsConfigurationError() throws {
        try requireBinary()
        let config = try writeTempConfig("""
        {"xctestrunPath": "/nonexistent/tests.xctestrun", "outputDirectoryPath": "/tmp/sift-cli-out",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "n", "host": "127.0.0.1", "port": 22, "username": "u",
                    "deploymentPath": "/tmp/d", "UDID": {"simulators": ["A"]},
                    "xcodePath": "/Applications/Xcode.app"}]}
        """)
        let result = try runCLI(["run", "-c", config])
        XCTAssertEqual(result.status, 64, "missing controller-side files are configuration errors")
    }

    func testTestsPathPlusOnlyTestingConflictExits64() throws {
        try requireBinary()
        let listFile = NSTemporaryDirectory() + "sift-cli-tests-\(UUID().uuidString).txt"
        try "B/C/testX()".write(toFile: listFile, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: listFile) }
        let config = try writeTempConfig("""
        {"xctestrunPath": "\(fixtureXctestrun)", "outputDirectoryPath": "/tmp/sift-cli-out",
         "rerunFailedTest": 0, "testsBucket": 1,
         "nodes": [{"name": "n", "host": "127.0.0.1", "port": 22, "username": "u",
                    "deploymentPath": "/tmp/d", "UDID": {"simulators": ["A"]},
                    "xcodePath": "/Applications/Xcode.app"}]}
        """)
        let result = try runCLI(["run", "-c", config, "-o", "B/C/testY()", "--tests-path", listFile])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("--combine-test-selectors"), result.stderr)
    }

    func testListRequiresConfigOrXctestrun() throws {
        try requireBinary()
        let result = try runCLI(["list"])
        XCTAssertEqual(result.status, 64)
    }

    func testListWithXctestrunNeedsNoConfigAndKeepsStdoutClean() throws {
        try requireBinary()
        // symbols backend against the committed fixture: its binaries don't exist on
        // this machine, so discovery fails — but the failure lands on STDERR with
        // exit 1, and stdout (the data stream) stays empty.
        let result = try runCLI(["list", "--xctestrun", fixtureXctestrun, "--discovery", "symbols"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.isEmpty, "no test names — stdout stays empty: \(result.stdout)")
        XCTAssertFalse(result.stderr.isEmpty)
    }
}
