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
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func requireBinary() throws {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw XCTSkip("Sift binary not present next to the test bundle (build the package first)")
        }
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
}
