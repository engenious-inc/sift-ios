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
    /// Test-plan configuration the test ran under (nil: none recorded / FormatVersion 1).
    public var configuration: String? = nil
    /// True when the last real verdict came from a HEALTHY chunk — only those
    /// durations feed the timings store (a timed-out/degraded chunk's numbers would
    /// pollute scheduling history).
    public var timingEligible: Bool = false
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

/// One discovered, runnable test with its full identity. The first identifier component
/// is the `.xctest` BUNDLE basename — the one namespace `xcodebuild -only-testing:` and
/// xcresult both speak — never `ProductModuleName` (which can differ, e.g. "My UITests"
/// vs "My_UITests").
public struct ScheduledTest: Sendable, Hashable {
    /// Test-plan configuration this test belongs to (nil for FormatVersion 1 / single-config).
    public let configurationName: String?
    /// The xctestrun target key (V1 root key / V2 BlueprintName).
    public let targetKey: String
    public let productModuleName: String
    /// `.xctest` bundle basename without extension — the canonical first identifier component.
    public let bundleName: String
    /// "Class" or "Outer/Inner" for nested classes.
    public let classPath: String
    /// Method name including "()".
    public let method: String

    public init(configurationName: String?, targetKey: String, productModuleName: String,
                bundleName: String, classPath: String, method: String) {
        self.configurationName = configurationName
        self.targetKey = targetKey
        self.productModuleName = productModuleName
        self.bundleName = bundleName
        self.classPath = classPath
        self.method = method
    }

    /// Stable report/scheduling identifier: "Bundle/Class/test()" — or
    /// "Bundle/test()" for suite-less tests (top-level Swift Testing functions).
    public var id: String {
        classPath.isEmpty ? "\(bundleName)/\(method)" : "\(bundleName)/\(classPath)/\(method)"
    }
}

/// One schedulable unit: a test identifier bound to the test-plan configuration it
/// runs under. In a multi-configuration run the same identifier appears once per
/// selected configuration; a lease never mixes configurations.
public struct TestUnit: Hashable, Sendable {
    public let configuration: String?
    /// Canonical "Bundle/Class/test()" identifier.
    public let test: String

    public init(configuration: String?, test: String) {
        self.configuration = configuration
        self.test = test
    }

    /// Report name: the plain identifier for single-configuration runs; qualified
    /// with the configuration when a run spans several (those runs were previously
    /// impossible, so the qualified form breaks no existing consumer).
    public func reportName(multiConfiguration: Bool) -> String {
        guard multiConfiguration, let configuration else { return test }
        return "\(test) [\(configuration)]"
    }
}

/// A user-supplied test selector: a full method, a class, or a whole bundle.
/// A trailing "()" is the ONE unambiguous method marker. A multi-component
/// selector WITHOUT it is matched against the discovered set under BOTH readings
/// (class-path prefix, and exact paren-less method) — never decided by a name
/// heuristic: "B/modernAdditionWorks" reaches a suite-less Swift Testing function,
/// and "B/testHelpers" reaches a class that happens to start with "test".
public enum TestSelector: Sendable, Hashable {
    case bundle(String)
    case method(bundle: String, classPath: String, method: String)
    /// Class-or-method: resolved against discovered identities at match time.
    case classOrMethod(bundle: String, components: [String])

    /// Parses "Bundle", "Bundle/Class", "Bundle/Outer/Inner", or "Bundle/Class/test[()]".
    public static func parse(_ raw: String) -> TestSelector? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = trimmed.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let last = components.last else { return nil }
        if components.count == 1 {
            return .bundle(last)
        }
        if last.hasSuffix("()") {
            components.removeLast()
            let bundle = components.removeFirst()
            return .method(bundle: bundle,
                           classPath: components.joined(separator: "/"),
                           method: TestName.canonical(last))
        }
        let bundle = components.removeFirst()
        return .classOrMethod(bundle: bundle, components: components)
    }

    public func matches(_ test: ScheduledTest) -> Bool {
        switch self {
        case .bundle(let bundle):
            return bundle == test.bundleName
        case .method(let bundle, let classPath, let method):
            return bundle == test.bundleName && test.classPath == classPath && test.method == method
        case .classOrMethod(let bundle, let components):
            guard bundle == test.bundleName, let last = components.last else { return false }
            // Class reading: the components are a class path (nested classes included).
            let classPath = components.joined(separator: "/")
            if test.classPath == classPath || test.classPath.hasPrefix(classPath + "/") {
                return true
            }
            // Method reading: the last component is a paren-less method name.
            return test.classPath == components.dropLast().joined(separator: "/")
                && test.method == TestName.canonical(last)
        }
    }

    public var description: String {
        switch self {
        case .bundle(let bundle): return bundle
        case .method(let bundle, let classPath, let method):
            return classPath.isEmpty ? "\(bundle)/\(method)" : "\(bundle)/\(classPath)/\(method)"
        case .classOrMethod(let bundle, let components):
            return "\(bundle)/\(components.joined(separator: "/"))"
        }
    }

    /// Expands user selectors against the discovered set. Selectors matching nothing are
    /// an error (close matches suggested) — a typo must never burn retries as a phantom test.
    public static func expand(
        rawSelectors: [String],
        against discovered: [ScheduledTest]
    ) throws -> [ScheduledTest] {
        // Dedupe by the FULL record: in a multi-configuration run the same identifier
        // legitimately appears once per configuration and every instance is scheduled.
        var seen = Set<ScheduledTest>()
        var result: [ScheduledTest] = []
        var unknown: [String] = []
        for raw in rawSelectors {
            guard let selector = parse(raw) else { continue }
            let matched = discovered.filter { selector.matches($0) }
            if matched.isEmpty {
                unknown.append(closeMatchMessage(for: raw, selector: selector, discovered: discovered))
                continue
            }
            for test in matched where seen.insert(test).inserted {
                result.append(test)
            }
        }
        guard unknown.isEmpty else {
            throw XCTestRunError(
                "Unknown test selector(s):\n" + unknown.map { "  - \($0)" }.joined(separator: "\n")
            )
        }
        return result
    }

    private static func closeMatchMessage(for raw: String, selector: TestSelector, discovered: [ScheduledTest]) -> String {
        let needle: String
        switch selector {
        case .bundle(let bundle): needle = bundle
        case .method(_, _, let method): needle = method.replacingOccurrences(of: "()", with: "")
        case .classOrMethod(_, let components): needle = components.last ?? ""
        }
        let lowered = needle.lowercased()
        let suggestions = discovered
            .map(\.id)
            .filter { id in
                if id.lowercased().contains(lowered) { return true }
                // Typo tolerance on the last two components (class, method).
                return id.components(separatedBy: "/").suffix(2).contains { component in
                    editDistance(component.replacingOccurrences(of: "()", with: "").lowercased(), lowered) <= 2
                }
            }
            .prefix(5)
        guard !suggestions.isEmpty else { return "'\(raw)' matches no discovered test" }
        return "'\(raw)' matches no discovered test — did you mean:\n" +
            suggestions.map { "      \($0)" }.joined(separator: "\n")
    }

    /// Bounded Levenshtein distance for typo suggestions (identifiers are short).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        guard abs(a.count - b.count) <= 2 else { return .max }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
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
