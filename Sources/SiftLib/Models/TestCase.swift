import Foundation

public struct TestCase: Hashable, Sendable {
    public enum State: Sendable {
        case pass
        case failed
        case unexecuted
    }
    
    public var name: String
    public var state: State
    public var launchCounter: Int
    public var duration: Double
    public var message: String
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

public actor TestCases {
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
    
    public func next(amount: Int) -> [String] {
        return (1...amount).compactMap { _ in self.iterator.next()?.key }
    }
    
    public func nextForRerun() -> String? {
        guard let test = failedTestsCache.popLast() else { return nil }
        return test
    }
    
    public func update(test: String, state: TestCase.State, duration: Double, message: String = "") {
        guard cases[test] != nil else { return }
        cases[test]!.state = state
        cases[test]!.launchCounter += 1
        cases[test]!.duration = duration
        cases[test]!.message = message
        if state != .pass && cases[test]!.launchCounter <= self.rerunLimit {
            failedTestsCache.append(test)
        }
    }
}

//extension TestCases: CustomStringConvertible {
//    public var description: String {
//        return cases.keys.sorted().joined(separator: "\n")
//    }
//}
