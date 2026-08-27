import XCTest
@testable import SiftLib

/// Integration tests against a local sshd. Skipped unless SIFT_TEST_SSH_PORT,
/// SIFT_TEST_SSH_USER, and SIFT_TEST_SSH_KEY are set (see README dev section).
final class SSHIntegrationTests: XCTestCase {

    private func makeConnectedSSH() async throws -> SSH {
        let environment = ProcessInfo.processInfo.environment
        guard let portString = environment["SIFT_TEST_SSH_PORT"],
              let port = Int32(portString),
              let user = environment["SIFT_TEST_SSH_USER"],
              let key = environment["SIFT_TEST_SSH_KEY"] else {
            throw XCTSkip("SIFT_TEST_SSH_* not configured")
        }
        let ssh = SSH(host: "127.0.0.1", port: port, arch: nil, hostKeyVerification: .acceptNew)
        try await ssh.connect(username: user, password: nil, privateKey: key, publicKey: nil, passphrase: nil)
        return ssh
    }

    func testRunCapturesStatusAndBothStreams() async throws {
        let ssh = try await makeConnectedSSH()
        let result = try await ssh.run("echo out; echo err >&2; exit 5")
        XCTAssertEqual(result.status, 5)
        XCTAssertTrue(result.output.contains("out"))
        XCTAssertTrue(result.output.contains("err"))
    }

    func testRunHandlesUnicodeAndLargeOutput() async throws {
        let ssh = try await makeConnectedSSH()
        // > 16KB of multibyte characters: exercises chunk-boundary decoding.
        let result = try await ssh.run("for i in $(seq 1 2000); do printf 'юникод-строка-🚀-%d\\n' $i; done")
        XCTAssertEqual(result.status, 0)
        let lines = result.output.split(separator: "\n")
        XCTAssertEqual(lines.count, 2000)
        XCTAssertTrue(lines.last!.contains("юникод-строка-🚀-2000"))
    }

    func testUploadDownloadRoundTrip() async throws {
        let ssh = try await makeConnectedSSH()
        let content = "sift-integration-\(UUID().uuidString)-юникод"
        let remotePath = "/tmp/sift-it-\(UUID().uuidString)"
        let localDownload = NSTemporaryDirectory() + "sift-it-download-\(UUID().uuidString)"
        try await ssh.uploadFile(data: Data(content.utf8), remotePath: remotePath)
        try await ssh.downloadFile(remotePath: remotePath, localPath: localDownload)
        defer {
            try? FileManager.default.removeItem(atPath: localDownload)
        }
        XCTAssertEqual(try String(contentsOfFile: localDownload, encoding: .utf8), content)
        // TRUNC behavior: overwriting with shorter content must not leave stale bytes.
        try await ssh.uploadFile(data: Data("short".utf8), remotePath: remotePath)
        try await ssh.downloadFile(remotePath: remotePath, localPath: localDownload)
        XCTAssertEqual(try String(contentsOfFile: localDownload, encoding: .utf8), "short")
        _ = try await ssh.run("rm -f \(remotePath.shellQuoted)")
    }

    func testTransferBenchmarkSessionReuseAndReconnect() async throws {
        let ssh = try await makeConnectedSSH()
        let remotePath = "/tmp/sift-bench-\(UUID().uuidString)"
        addTeardownBlock { _ = try? await ssh.run("rm -f \(remotePath.shellQuoted)") }
        // 32 MB synthetic payload; timings recorded, never asserted (machines differ).
        let payloadPath = NSTemporaryDirectory() + "sift-bench-\(UUID().uuidString).bin"
        let payload = Data((0..<(32 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: URL(fileURLWithPath: payloadPath))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: payloadPath) }

        let start = Date()
        try await ssh.uploadFile(localPath: payloadPath, remotePath: remotePath)
        let firstUpload = Date().timeIntervalSince(start)
        // Second transfer reuses the cached SFTP channel (no re-open round-trip).
        let start2 = Date()
        try await ssh.uploadFile(localPath: payloadPath, remotePath: remotePath)
        let secondUpload = Date().timeIntervalSince(start2)
        print("[bench] 32MB SFTP upload: first \(String(format: "%.2f", firstUpload))s, cached-channel \(String(format: "%.2f", secondUpload))s")

        // Short final write + overwrite truncation still correct through the cache.
        try await ssh.uploadFile(data: Data("tiny".utf8), remotePath: remotePath)
        let check = try await ssh.run("wc -c < \(remotePath.shellQuoted)")
        XCTAssertEqual(check.output.trimmingCharacters(in: .whitespacesAndNewlines), "4")
    }

    func testBackgroundProcessLifecycle() async throws {
        let ssh = try await makeConnectedSSH()
        let workDirectory = "/tmp/sift-bg-\(UUID().uuidString)"
        addTeardownBlock { _ = try? await ssh.run("rm -rf \(workDirectory.shellQuoted)") }

        let handle = try await ssh.startBackgroundProcess(
            command: "echo started; sleep 1; echo done; exit 7",
            workDirectory: workDirectory,
            attemptID: "attempt-1"
        )
        // Still running initially.
        let early = try await ssh.pollBackgroundProcess(handle)
        XCTAssertNil(early)
        // Completes with the real exit status.
        var status: Int32?
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            status = try await ssh.pollBackgroundProcess(handle)
            if status != nil { break }
        }
        XCTAssertEqual(status, 7)
        let log = try await ssh.run("cat \(handle.logPath.shellQuoted)")
        XCTAssertTrue(log.output.contains("started"))
        XCTAssertTrue(log.output.contains("done"))
    }

    func testBackgroundProcessTermination() async throws {
        let ssh = try await makeConnectedSSH()
        let workDirectory = "/tmp/sift-bg-\(UUID().uuidString)"
        addTeardownBlock { _ = try? await ssh.run("rm -rf \(workDirectory.shellQuoted)") }

        let handle = try await ssh.startBackgroundProcess(
            command: "sleep 300",
            workDirectory: workDirectory,
            attemptID: "attempt-kill"
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let initialPoll = try await ssh.pollBackgroundProcess(handle)
        XCTAssertNil(initialPoll)

        let pid = try await ssh.run("cat \(handle.pidPath.shellQuoted)").output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(pid.isEmpty, "wrapper pid must be recorded")

        await ssh.terminateBackgroundProcess(handle, marker: "sift-attempt:attempt-kill")
        // The wrapper and its sleep child must both be gone.
        let alive = try await ssh.run("ps -p \(pid) > /dev/null 2>&1 && echo ALIVE || echo DEAD")
        XCTAssertTrue(alive.output.contains("DEAD"))
    }

    func testTerminationRefusesWrongMarker() async throws {
        let ssh = try await makeConnectedSSH()
        let workDirectory = "/tmp/sift-bg-\(UUID().uuidString)"
        addTeardownBlock { _ = try? await ssh.run("rm -rf \(workDirectory.shellQuoted)") }

        let handle = try await ssh.startBackgroundProcess(
            command: "sleep 5; exit 0",
            workDirectory: workDirectory,
            attemptID: "attempt-safe"
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        // A mismatched marker must never kill the process.
        await ssh.terminateBackgroundProcess(handle, marker: "some-other-run-entirely")
        let pid = try await ssh.run("cat \(handle.pidPath.shellQuoted)").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let alive = try await ssh.run("ps -p \(pid) > /dev/null 2>&1 && echo ALIVE || echo DEAD")
        XCTAssertTrue(alive.output.contains("ALIVE"))
    }
}
