import Foundation

public struct TestCase: Hashable {
    public enum State {
        case pass
        case failed
        case unexecuted
    }
    
    public var id: Int? = nil
    public var name: String
    public var state: State
    public var launchCounter: Int
    public var duration: Double
    public var message: String
    public var screenshotID: String?
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
    
    public func resultFormatted() -> String {
        switch state {
        case .pass:
            if launchCounter > 1 { return "passed_after_rerun" }
            return "passed"
        case .failed:
            return "failed"
        case .unexecuted:
            return "skipped"
        }
    }
}

public struct TestCases {
    private var iterator: IndexingIterator<[(key: String, case: TestCase)]>
    private var failedTestsCache: [String] = []
    private let rerunLimit: Int
    public var cases: [String: TestCase]
    
    public var count: Int { cases.count }
    public var passed: [TestCase] { cases.values.filter { $0.state == .pass } }
    public var reran: [TestCase] { cases.values.filter { $0.launchCounter > 1 } }
    public var failed: [TestCase] { cases.values.filter { $0.state == .failed } }
    public var unexecuted: [TestCase] { cases.values.filter { $0.state == .unexecuted } }

    public init(tests: [String], rerunLimit: Int) {
        let cases = tests.map {
            (key: $0, case: TestCase(name: $0, state: .unexecuted, launchCounter: 0, duration: 0.0, message: ""))
        }
        self.cases = Dictionary<String, TestCase>(uniqueKeysWithValues: cases)
        self.iterator = cases.makeIterator()
        self.rerunLimit = rerunLimit
    }
    
    public init(tests: [Config.Test], rerunLimit: Int) {
        let cases = tests.map {
            (key: $0.testName, case: TestCase(id: $0.testID, name: $0.testName, state: .unexecuted, launchCounter: 0, duration: 0.0, message: ""))
        }
        self.cases = Dictionary<String, TestCase>(uniqueKeysWithValues: cases)
        self.iterator = cases.makeIterator()
        self.rerunLimit = rerunLimit
    }
    
    public mutating func next(amount: Int) -> [String] {
        return (1...amount).compactMap { _ in self.iterator.next()?.key }
    }
    
    public mutating func nextForRerun() -> String? {
        guard let test = failedTestsCache.popLast() else { return nil }
        return test
    }
    
    public mutating func update(test: String, state: TestCase.State, duration: Double, message: String = "", screenshotID: String? = nil) {
        guard cases[test] != nil else { return }
        cases[test]!.state = state
        cases[test]!.launchCounter += 1
        cases[test]!.duration = duration
        cases[test]!.message = message
        cases[test]!.screenshotID = screenshotID
        if state != .pass && cases[test]!.launchCounter <= self.rerunLimit {
            failedTestsCache.append(test)
        }
    }
}

extension TestCases: CustomStringConvertible {
    public var description: String {
        return cases.keys.sorted().joined(separator: "\n")
    }
}
