import Foundation
@testable import SiftLib

/// Scriptable in-memory SSHExecutor for deterministic Node/Xcodebuild behavior tests.
/// Commands are recorded; background-process polls are served from a scripted queue.
final class FakeSSHExecutor: SSHExecutor, @unchecked Sendable {

    struct State {
        var commandLog: [String] = []
        var pollResults: [Int32?] = []
        /// Status the wrapper "wrote" after a terminate (nil = no status file).
        var postTerminateStatus: Int32?
        var terminations: [(handle: BackgroundProcessHandle, marker: String)] = []
        var connectAttempts = 0
        var connectFailuresRemaining = 0
        var commandFailuresForPrefix: [String: Int32] = [:]
        var downloads: [(remote: String, local: String, abortable: Bool)] = []
        var terminated = false
    }

    private let lock = NSLock()
    private var state = State()

    struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&state)
    }

    var commandLog: [String] { withState { $0.commandLog } }

    // MARK: - SSHExecutor

    init(host: String, port: Int32, arch: Config.NodeConfig.Arch?, hostKeyVerification: Config.NodeConfig.HostKeyVerification) {}
    init() {}

    func connect(username: String, password: String?, privateKey: String?, publicKey: String?, passphrase: String?) async throws {
        try withState { state in
            state.connectAttempts += 1
            if state.connectFailuresRemaining > 0 {
                state.connectFailuresRemaining -= 1
                throw FakeError(description: "scripted connect failure")
            }
        }
    }

    @discardableResult
    func run(_ command: String) async throws -> (status: Int32, output: String) {
        try withState { state in
            state.commandLog.append(command)
            for (prefix, status) in state.commandFailuresForPrefix where command.hasPrefix(prefix) {
                if status == -1 { throw FakeError(description: "scripted command failure for \(prefix)") }
                return (status, "scripted failure output")
            }
            if command.contains("simctl list devices --json") {
                let json = """
                {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                  {"udid": "FAKE-UDID-1", "state": "Booted", "isAvailable": true, "name": "Fake iPhone"}
                ]}}
                """
                return (0, json)
            }
            return (0, "")
        }
    }

    func uploadFile(localPath: String, remotePath: String) async throws {}
    func uploadFile(data: Data, remotePath: String) async throws {}

    func downloadFile(remotePath: String, localPath: String, abortOnCancellation: Bool) async throws {
        withState { $0.downloads.append((remotePath, localPath, abortOnCancellation)) }
        // Produce an empty file so callers see "a download happened".
        FileManager.default.createFile(atPath: localPath, contents: Data())
    }

    func startBackgroundProcess(command: String, workDirectory: String, attemptID: String) async throws -> BackgroundProcessHandle {
        withState { $0.commandLog.append("START-BG \(attemptID)") }
        return BackgroundProcessHandle(attemptID: attemptID, directory: "\(workDirectory)/proc/\(attemptID)")
    }

    func pollBackgroundProcess(_ handle: BackgroundProcessHandle) async throws -> Int32? {
        withState { state in
            if state.terminated { return state.postTerminateStatus }
            guard !state.pollResults.isEmpty else { return nil }
            return state.pollResults.removeFirst()
        }
    }

    @discardableResult
    func terminateBackgroundProcess(_ handle: BackgroundProcessHandle, marker: String) async -> TerminationOutcome {
        withState { state in
            state.terminations.append((handle, marker))
            state.terminated = true
        }
        return .confirmedDead
    }

    func terminateOwnedProcesses(workDirectory: String) async -> [TerminationOutcome] {
        withState { $0.commandLog.append("SWEEP \(workDirectory)") }
        return []
    }
}
