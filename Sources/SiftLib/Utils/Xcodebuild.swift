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
        /// Why the chunk ended — chunk HEALTH derives from this + status, never from
        /// `Task.isCancelled` (which can flip after a clean exit).
        enum EndReason: Sendable {
            /// The xcodebuild process exited on its own.
            case exited
            /// Sift killed it at the chunk deadline.
            case timedOut
            /// The run was cancelled; the process was terminated (or had just exited).
            case cancelled
        }
        let status: Int
        let endReason: EndReason
        let attemptID: String
        /// Path (on the node) of the exact result bundle this attempt produced.
        let resultBundlePath: String
        /// Path (on the node) of the wrapper's full combined xcodebuild log.
        let remoteLogPath: String
        let logTail: String
    }

    /// Runs one chunk. The xcodebuild process is owned: its pid is recorded on the
    /// node and it is TERM/KILL-ed if the timeout expires — never left orphaned.
    /// `configuration` is the lease's configuration: when present it overrides the
    /// global selectors (selection was already resolved at scheduling time).
    func execute(tests: [String],
                 configuration: String? = nil,
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
        if let configuration {
            arguments += ["-only-test-configuration", configuration]
        } else {
            if let onlyTestConfiguration {
                arguments += ["-only-test-configuration", onlyTestConfiguration]
            }
            if let skipTestConfiguration {
                arguments += ["-skip-test-configuration", skipTestConfiguration]
            }
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

        // Monotonic clock: never affected by NTP steps or wall-clock changes.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(testsExecutionTimeout))
        let pollInterval: Duration = .seconds(3)
        var status: Int32?
        var endReason: ChunkResult.EndReason = .exited
        do {
            while true {
                let remaining = clock.now.duration(to: deadline)
                if remaining <= .zero {
                    // Poll once more before killing: a completed status is a completed
                    // chunk even at the deadline edge (its verdicts are real).
                    status = try await shell.pollBackgroundProcess(handle)
                    if status == nil {
                        log?.error("xcodebuild chunk timed out after \(testsExecutionTimeout)s on \(UDID) — terminating")
                        await shell.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
                        status = 143
                        endReason = .timedOut
                    }
                    break
                }
                try await Task.sleep(for: min(pollInterval, remaining))
                status = try await shell.pollBackgroundProcess(handle)
                if status != nil { break }
            }
        } catch is CancellationError {
            // Run cancelled mid-chunk: terminate with the FULL (shielded) TERM grace,
            // then read the status the wrapper may have written — xcodebuild that
            // finalized a bundle on TERM is salvageable, and the caller collects it.
            await shell.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            status = try? await shell.pollBackgroundProcess(handle)
            endReason = .cancelled
        } catch {
            // A polling failure must never orphan the remote process.
            await shell.terminateBackgroundProcess(handle, marker: "sift-attempt:\(attemptID)")
            throw error
        }

        let logTail = (try? await shell.run("tail -c 4000 \(handle.logPath.shellQuoted)").output) ?? ""
        return ChunkResult(
            status: Int(status ?? 143),
            endReason: endReason,
            attemptID: attemptID,
            resultBundlePath: resultBundlePath,
            remoteLogPath: handle.logPath,
            logTail: logTail
        )
    }
}
