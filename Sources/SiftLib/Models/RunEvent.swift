import Foundation

/// One machine-readable run event (NDJSON line). Schema v1; `data` is a flat
/// string map so consumers never chase nested types.
public struct RunEvent: Codable, Sendable {
    public let version: Int
    public let timestamp: Date
    public let kind: String
    public let data: [String: String]
}

/// Fan-out for run events: an optional NDJSON file, optional stdout echo, and
/// in-process consumers (the TTY progress line). Emission is fire-and-forget —
/// events must never slow or fail a run.
public actor EventBus {
    public typealias Consumer = @Sendable (RunEvent) -> Void

    private var fileHandle: FileHandle?
    private var echoToStdout: Bool
    private let consumers: [Consumer]
    private let encoder: JSONEncoder

    public init(ndjsonPath: String? = nil, echoToStdout: Bool = false, consumers: [Consumer] = []) {
        self.echoToStdout = echoToStdout
        self.consumers = consumers
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        if let ndjsonPath {
            FileManager.default.createFile(atPath: ndjsonPath, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
            self.fileHandle = FileHandle(forWritingAtPath: ndjsonPath)
            if fileHandle == nil {
                // Never silent: a CI dashboard waiting on this stream gets nothing.
                Self.warn("cannot open --events-path \(ndjsonPath) for writing — no events will be recorded")
            }
        }
    }

    /// Diagnostics go to stderr, never stdout (which the NDJSON stream may own).
    private static func warn(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(("\n ⚠️   " + message + "\n").utf8))
    }

    /// Throwing writes only: the legacy `write(_:)` raises an uncatchable ObjC
    /// exception on ENOSPC/EPIPE and would abort the whole run. A sink that fails
    /// is reported once and disabled — events must never fail or stall a run.
    public func emit(_ kind: String, _ data: [String: String] = [:]) {
        let event = RunEvent(version: 1, timestamp: Date(), kind: kind, data: data)
        if fileHandle != nil || echoToStdout, let encoded = try? encoder.encode(event) {
            var line = encoded
            line.append(0x0A)
            if let fileHandle {
                do {
                    try fileHandle.write(contentsOf: line)
                } catch {
                    Self.warn("event stream write failed (\(error)) — disabling --events-path output")
                    try? fileHandle.close()
                    self.fileHandle = nil
                }
            }
            if echoToStdout {
                do {
                    try FileHandle.standardOutput.write(contentsOf: line)
                } catch {
                    Self.warn("stdout event stream write failed (\(error)) — disabling --events-stdout output")
                    echoToStdout = false
                }
            }
        }
        for consumer in consumers {
            consumer(event)
        }
    }

    public func finish() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}

/// Live single-line TTY progress, driven purely by run events: done/pending/
/// in-flight counts, failures, active chunks, and elapsed execution time.
/// (Off a TTY the per-test result lines in the normal log are the line-oriented
/// progress stream; this single rewriting line is TTY-only.)
public final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var finished = Set<String>()
    private var failed = 0
    private var activeChunks = 0
    /// Tests currently leased, per executor (chunkStarted carries the count).
    private var inFlightByExecutor: [String: Int] = [:]
    private var startedAt: Double?
    private let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public var consumer: EventBus.Consumer {
        { [weak self] event in self?.consume(event) }
    }

    private static func monotonicNow() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private func consume(_ event: RunEvent) {
        guard enabled else { return }
        lock.lock()
        switch event.kind {
        case "runStarted":
            total = Int(event.data["tests"] ?? "") ?? 0
            startedAt = Self.monotonicNow()
        case "chunkStarted":
            activeChunks += 1
            if let executor = event.data["executor"] {
                inFlightByExecutor[executor] = Int(event.data["tests"] ?? "") ?? 0
            }
        case "chunkFinished":
            activeChunks = max(0, activeChunks - 1)
            if let executor = event.data["executor"] {
                inFlightByExecutor[executor] = nil
            }
        case "testFinished":
            if let test = event.data["test"], event.data["outcome"] != "notExecuted" {
                // Key by (configuration, test): in a multi-configuration run the
                // same identifier legitimately finishes once per configuration.
                finished.insert("\(event.data["configuration"] ?? "")|\(test)")
                if event.data["outcome"] == "failed" { failed += 1 }
            }
        case "runFinished":
            lock.unlock()
            if total > 0 { print("") }
            return
        default:
            break
        }
        let inFlight = inFlightByExecutor.values.reduce(0, +)
        let pending = max(0, total - finished.count - inFlight)
        let elapsed = startedAt.map { Int(Self.monotonicNow() - $0) } ?? 0
        let line = "\r⏳ \(finished.count)/\(total) done · \(pending) pending · \(inFlight) running in \(activeChunks) chunk(s) · \(failed) failed · \(elapsed)s   "
        lock.unlock()
        if total > 0 {
            // A closed stdout (EPIPE) is not a reason to abort the run.
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
    }
}
