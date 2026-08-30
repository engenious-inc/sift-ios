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
    private let echoToStdout: Bool
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
        }
    }

    public func emit(_ kind: String, _ data: [String: String] = [:]) {
        let event = RunEvent(version: 1, timestamp: Date(), kind: kind, data: data)
        if fileHandle != nil || echoToStdout, let encoded = try? encoder.encode(event) {
            var line = encoded
            line.append(0x0A)
            fileHandle?.write(line)
            if echoToStdout {
                FileHandle.standardOutput.write(line)
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
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
