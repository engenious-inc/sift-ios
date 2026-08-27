import Foundation

struct Xcodebuild {

    let xcodePath: String
    let shell: SSHExecutor
    /// Wall-clock budget for one chunk of tests, in seconds.
    let testsExecutionTimeout: Int
    let onlyTestConfiguration: String?
    let skipTestConfiguration: String?
    /// Recorded xctestruns can carry ParallelizationEnabled=true; unless the user
    /// explicitly opts in, Sift disables xcodebuild's own parallel testing so a chunk
    /// can never spawn untracked simulator clones behind the scheduler's back.
    var allowXcodebuildParallelTesting: Bool = false

    struct ChunkResult {
        let status: Int
        /// Path (on the node) of the exact result bundle this attempt produced.
        let resultBundlePath: String
        let logTail: String
    }

    /// Runs one chunk. The xcodebuild process is owned: its pid is recorded on the
    /// node and it is TERM/KILL-ed if the timeout expires — never left orphaned.
    func execute(tests: [String],
                 executorType: TestExecutorType,
                 UDID: String,
                 xctestrunPath: String,
                 workDirectory: String,
                 log: Logging?) async throws -> ChunkResult {
        let attemptID = UUID().uuidString
        let resultBundlePath = "\(workDirectory)/results/\(UDID)/\(attemptID).xcresult"

        var arguments: [String] = [
            "xcodebuild",
            "-xctestrun", xctestrunPath,
            "-destination", "platform=\(executorType.rawValue),id=\(UDID)",
            "-derivedDataPath", "\(workDirectory)/dd/\(UDID)",
            "-resultBundlePath", resultBundlePath,
            "-test-timeouts-enabled", "YES",
        ]
        if !allowXcodebuildParallelTesting {
            arguments += ["-parallel-testing-enabled", "NO"]
        }
        if let onlyTestConfiguration {
            arguments += ["-only-test-configuration", onlyTestConfiguration]
        }
        if let skipTestConfiguration {
            arguments += ["-skip-test-configuration", skipTestConfiguration]
        }
        arguments += tests.map { "-only-testing:\($0)" }
        arguments.append("test-without-building")

        let command = "export DEVELOPER_DIR=\((xcodePath + "/Contents/Developer").shellQuoted); "
            + arguments.shellQuotedJoined
        log?.message(verboseMsg: "Run command:\n" + command)

        let handle = try await shell.startBackgroundProcess(
            command: command,
            workDirectory: workDirectory,
            attemptID: attemptID
        )

        let pollInterval: UInt64 = 3
        let deadline = Date().addingTimeInterval(TimeInterval(testsExecutionTimeout))
        var status: Int32?
        do {
            while true {
                try await Task.sleep(nanoseconds: pollInterval * 1_000_000_000)
                status = try await shell.pollBackgroundProcess(handle)
                if status != nil { break }
                if Date() >= deadline {
                    log?.error("xcodebuild chunk timed out after \(testsExecutionTimeout)s on \(UDID) — terminating")
                    await shell.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
                    status = 143
                    break
                }
            }
        } catch {
            // Cancellation or a polling failure must never orphan the remote process.
            await shell.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            throw error
        }

        let logTail = (try? await shell.run("tail -c 4000 \(handle.logPath.shellQuoted)").output) ?? ""
        return ChunkResult(status: Int(status ?? -1), resultBundlePath: resultBundlePath, logTail: logTail)
    }
}
