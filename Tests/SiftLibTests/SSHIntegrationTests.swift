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

    /// Regression: the upload loop used to pin every chunk in the serial queue's
    /// undrained autorelease pool, so controller RSS grew by the archive size per
    /// in-flight node (a 6 GiB build fanned out to 11 nodes got the controller
    /// SIGKILLed by the kernel). The footprint must stay flat regardless of size.
    func testLargeUploadKeepsControllerFootprintFlat() async throws {
        let ssh = try await makeConnectedSSH()
        let remotePath = "/tmp/sift-footprint-\(UUID().uuidString)"
        addTeardownBlock { _ = try? await ssh.run("rm -f \(remotePath.shellQuoted)") }
        // Sparse 1 GiB file: reads return zeros without touching the disk.
        let payloadBytes: UInt64 = 1024 * 1024 * 1024
        let payloadPath = NSTemporaryDirectory() + "sift-footprint-\(UUID().uuidString).bin"
        XCTAssertTrue(FileManager.default.createFile(atPath: payloadPath, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: payloadPath))
        try handle.truncate(atOffset: payloadBytes)
        try handle.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: payloadPath) }

        let before = try XCTUnwrap(Self.residentMB(), "resident-size query failed before the upload")
        let sampler = PeakSampler()
        let sampling = Task.detached { await sampler.run() }
        // The sampler stops on every exit path (an upload error must not leave a
        // detached task sampling for the rest of the test process).
        let upload: Result<Void, any Error>
        do {
            try await ssh.uploadFile(localPath: payloadPath, remotePath: remotePath)
            upload = .success(())
        } catch {
            upload = .failure(error)
        }
        sampler.stop()
        await sampling.value
        try upload.get()
        let peak = try XCTUnwrap(sampler.peakMB, "no valid resident-size sample was taken during the upload")
        XCTAssertGreaterThan(sampler.sampleCount, 5, "the upload should be long enough to sample repeatedly")
        let growth = peak - before
        print("[footprint] 1 GiB SFTP upload: RSS before \(before) MB, peak \(peak) MB over \(sampler.sampleCount) samples, growth \(growth) MB")
        XCTAssertLessThan(growth, 256, "controller RSS grew by \(growth) MB during a 1 GiB upload — chunks are being retained")

        let size = try await ssh.run("wc -c < \(remotePath.shellQuoted)")
        XCTAssertEqual(size.output.trimmingCharacters(in: .whitespacesAndNewlines), "\(payloadBytes)")
    }

    /// This process's resident size in MB, or nil when the kernel query fails —
    /// a failed measurement must never masquerade as a small one.
    private static func residentMB() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : nil
    }

    /// Samples this process's resident size every 100 ms until stopped; failed
    /// queries are not counted.
    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var peak: Int?
        private var samples = 0
        var peakMB: Int? { lock.lock(); defer { lock.unlock() }; return peak }
        var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return samples }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        /// Records one sample; returns true once `stop()` was called.
        private func record(_ now: Int?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let now {
                peak = max(peak ?? 0, now)
                samples += 1
            }
            return stopped
        }
        func run() async {
            while !record(SSHIntegrationTests.residentMB()) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
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
