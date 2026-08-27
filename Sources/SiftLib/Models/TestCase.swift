import Foundation

public struct TestCase: Hashable, Sendable {
    public enum State: String, Sendable {
        case pass
        case failed
        case skipped
        case unexecuted
    }

    public var name: String
    public var state: State
    /// Number of times the test was actually launched (test-failure reruns included).
    public var launchCounter: Int
    /// Number of times the test was handed out but produced no result (infrastructure failures).
    public var infrastructureAttempts: Int
    public var duration: Double
    public var message: String
}

/// One test's result from one executed chunk.
public struct TestOutcome: Sendable {
    public enum Kind: Sendable {
        case pass
        case failed
        case skipped
        /// The test was in the chunk but the result bundle carries no verdict for it
        /// (crash before start, transfer failure, unparsable results).
        case notExecuted
    }

    public let test: String
    public let kind: Kind
    public let duration: Double
    public let message: String

    public init(test: String, kind: Kind, duration: Double = 0, message: String = "") {
        self.test = test
        self.kind = kind
        self.duration = duration
        self.message = message
    }
}

/// One recorded execution attempt (real run, infrastructure failure, or
/// abandoned lease) of one test.
public struct TestAttempt: Sendable {
    public let test: String
    public let executorID: String
    public let kind: TestOutcome.Kind
    public let duration: Double
    public let message: String
    /// When the lease containing this test was handed to the executor.
    public let startedAt: Date
    /// When the lease was completed or abandoned.
    public let endedAt: Date
}

/// Immutable view of all test states, taken in a single actor hop — reports consume only this.
public struct TestCasesSnapshot: Sendable {
    public let cases: [TestCase]
    public let attempts: [TestAttempt]

    public init(cases: [TestCase], attempts: [TestAttempt] = []) {
        self.cases = cases
        self.attempts = attempts
    }

    public var count: Int { cases.count }
    public var passed: [TestCase] { cases.filter { $0.state == .pass } }
    public var rerun: [TestCase] { cases.filter { $0.launchCounter > 1 } }
    public var skipped: [TestCase] { cases.filter { $0.state == .skipped } }
    public var failed: [TestCase] { cases.filter { $0.state == .failed } }
    public var unexecuted: [TestCase] { cases.filter { $0.state == .unexecuted } }
    public var sortedNames: [String] { cases.map(\.name).sorted() }
}

/// Canonical test identifier handling. The dumped-bundle form ("Module/Class/testName()")
/// is canonical; user input with or without trailing parens, CRLF, or stray whitespace
/// normalizes to it. One representation is used for scheduling, xcodebuild arguments,
/// result matching, and reports.
public enum TestName {
    public static func canonical(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return name }
        if !name.hasSuffix(")") {
            name += "()"
        }
        return name
    }

    public static func canonicalList<S: Sequence>(_ raw: S) -> [String] where S.Element == String {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let name = canonical(entry)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }
}
